local M = {}

local function cache_path(kind)
  -- kind: "chats" etc.
  local dir = vim.fn.stdpath("cache") .. "/ms-teams"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. kind .. ".json"
end

function M.load(kind, max_age_secs)
  local path = cache_path(kind)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local data = vim.fn.readfile(path)
  if #data == 0 then return nil end
  local ok, j = pcall(vim.json.decode, table.concat(data, "\n"))
  if not ok or not j then return nil end
  if max_age_secs and j._ts then
    if os.time() - j._ts > max_age_secs then return nil end
  end
  return j
end

function M.save(kind, payload)
  local path = cache_path(kind)
  payload._ts = os.time()
  vim.fn.writefile({ vim.json.encode(payload) }, path)
  pcall(vim.fn.system, { "chmod", "600", path })
end

function M.is_fresh(kind, max_age_secs)
  local j = M.load(kind, nil)
  if not j or not j._ts then return false end
  return os.time() - j._ts < (max_age_secs or 300)
end

-- lastRead overrides per chat (emulate Teams per-message unread)
local function last_read_path()
  local dir = vim.fn.stdpath("data") .. "/ms-teams"
  vim.fn.mkdir(dir, "p")
  return dir .. "/last_read.json"
end

function M.get_last_read(chat_id)
  local path = last_read_path()
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, j = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or not j then return nil end
  return j[chat_id]
end

function M.set_last_read(chat_id, iso)
  local path = last_read_path()
  local j = {}
  if vim.fn.filereadable(path) == 1 then
    local ok, cur = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    if ok and cur then j = cur end
  end
  if iso then
    j[chat_id] = iso
  else
    j[chat_id] = nil
  end
  vim.fn.writefile({ vim.json.encode(j) }, path)
  pcall(vim.fn.system, { "chmod", "600", path })
end

function M.clear_last_read(chat_id)
  M.set_last_read(chat_id, nil)
end

function M.save_me(me)
  local path = vim.fn.stdpath("data") .. "/ms-teams/me.json"
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(me) }, path)
  pcall(vim.fn.system, { "chmod", "600", path })
end

return M
