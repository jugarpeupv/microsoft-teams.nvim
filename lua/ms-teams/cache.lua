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

local function review_from_path()
  local dir = vim.fn.stdpath("data") .. "/ms-teams"
  return dir .. "/review_from.json"
end

-- mu review point: messages newer than this render highlighted in the
-- detail (including own) until mr clears it. List-level has_unread()
-- intentionally keeps excluding self.
function M.get_review_from(chat_id)
  local path = review_from_path()
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, j = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or not j then return nil end
  return j[chat_id]
end

function M.set_review_from(chat_id, iso)
  local path = review_from_path()
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

function M.clear_review_from(chat_id)
  M.set_review_from(chat_id, nil)
end

-- oneOnOne members for display names: fetched once via get_chat, then
-- reused from disk (names barely change). Only successful fetches are
-- stored, so failures retry on the next open.
local MEMBERS_TTL = 7 * 24 * 3600
function M.get_cached_members(chat_id)
  if not chat_id then return nil end
  local ok, j = pcall(M.load, "oneonone_members", MEMBERS_TTL)
  if not ok or type(j) ~= "table" or type(j.members) ~= "table" then return nil end
  local m = j.members[chat_id]
  if type(m) == "table" and #m > 0 then return m end
  return nil
end

function M.save_cached_members(chat_id, members)
  if not chat_id or type(members) ~= "table" or #members == 0 then return end
  local j = nil
  pcall(function() j = M.load("oneonone_members", nil) end)
  if type(j) ~= "table" then j = {} end
  if type(j.members) ~= "table" then j.members = {} end
  j.members[chat_id] = members
  M.save("oneonone_members", j)
end

function M.save_me(me)
  local path = vim.fn.stdpath("data") .. "/ms-teams/me.json"
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(me) }, path)
  pcall(vim.fn.system, { "chmod", "600", path })
end

return M
