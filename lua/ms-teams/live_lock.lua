-- Per-chat single-writer lock for the 1:1 live refresh poll. Same machine,
-- same data_dir: a JSON file per chat with the owner pid + heartbeat.
-- Ownership follows the editor the user is actually in: the most recently
-- opened/focused instance STEALS the lock (last one wins) and the previous
-- owner is told who took over (pid, process name, cwd). Hidden/closed buffers
-- release the lock; a missing/dead/stale lock is taken over as well.
local config = require("ms-teams.config")

local M = {}

local function lock_dir()
  local d = (config.options.data_dir or (vim.fn.stdpath("data") .. "/ms-teams")) .. "/live"
  vim.fn.mkdir(d, "p")
  return d
end

local function lock_path(chat_id)
  local safe = (chat_id or "unknown"):gsub("[^%w%-_]", "_"):sub(1, 120)
  return lock_dir() .. "/" .. safe .. ".lock"
end

local function read_lock(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then return nil end
  local ok2, j = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok2 and type(j) == "table" then return j end
  return nil
end

local function pid_alive(pid)
  pid = tonumber(pid)
  if not pid or pid <= 0 then return false end
  local uv = vim.uv or vim.loop
  if not (uv and uv.kill) then return true end
  -- uv.kill returns 0 on success; ESRCH = gone, EPERM = exists but not ours
  local ok, ret, err = pcall(uv.kill, pid, 0)
  if not ok then return true end
  if ret == 0 then return true end
  if err and tostring(err):find("EPERM") then return true end
  return false
end

-- heartbeat older than this means the owner is gone/frozen
local function ttl_secs(interval_ms)
  local secs = math.floor((tonumber(interval_ms) or 10000) / 1000)
  return math.max(30, secs * 3)
end

local function write_owner(chat_id)
  local path = lock_path(chat_id)
  local now = os.time()
  local me = vim.fn.getpid()
  local cur = read_lock(path)
  local started = (cur and tonumber(cur.pid) == me and cur.started_at) or now
  local data = {
    pid = me,
    chat_id = chat_id,
    started_at = started,
    heartbeat = now,
    proc = vim.fn.fnamemodify(vim.v.progpath or "nvim", ":t"),
    cwd = vim.fn.getcwd(),
  }
  pcall(vim.fn.writefile, { vim.json.encode(data) }, path)
  -- last writer wins; re-read so a simultaneous claim cannot leave both
  -- instances polling past this tick
  local check = read_lock(path)
  if check and tonumber(check.pid) == me then return true, data, cur end
  return false, check, cur
end

-- Take ownership unconditionally: used when a buffer is opened/focused, so the
-- editor the user is in wins over an older instance. Returns ok, own data and
-- the previous owner (so callers can announce the takeover).
function M.steal(chat_id)
  return write_owner(chat_id)
end

-- Refresh ownership for this tick. Returns true when we own it; false + owner
-- info when another live instance holds a fresh lock (do not steal here, or
-- two instances would ping-pong every tick).
function M.renew(chat_id, interval_ms)
  local cur = read_lock(lock_path(chat_id))
  local me = vim.fn.getpid()
  if cur and tonumber(cur.pid) and tonumber(cur.pid) ~= me then
    local fresh = (os.time() - (tonumber(cur.heartbeat) or 0)) < ttl_secs(interval_ms)
    if pid_alive(cur.pid) and fresh then return false, cur end
  end
  return write_owner(chat_id)
end

-- Human description of the current owner, for "lock was stolen" notices.
function M.describe(owner)
  if not owner then return "another Neovim instance" end
  local pid = tostring(owner.pid or "?")
  local proc = (owner.proc and owner.proc ~= "") and owner.proc or "nvim"
  local cwd = (owner.cwd and owner.cwd ~= "") and owner.cwd or "?"
  return string.format("PID %s (%s) cwd=%s", pid, proc, cwd)
end

function M.release(chat_id)
  local path = lock_path(chat_id)
  local cur = read_lock(path)
  if cur and tonumber(cur.pid) == vim.fn.getpid() then
    pcall(vim.fn.delete, path)
  end
end

function M.owner(chat_id)
  return read_lock(lock_path(chat_id))
end

-- don't leave stale locks behind when this editor exits
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    local ok, files = pcall(vim.fn.glob, lock_dir() .. "/*.lock", false, true)
    if not ok then return end
    for _, f in ipairs(files) do
      local j = read_lock(f)
      if j and tonumber(j.pid) == vim.fn.getpid() then pcall(vim.fn.delete, f) end
    end
  end,
})

return M
