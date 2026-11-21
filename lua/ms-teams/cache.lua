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
-- Graph gives two id forms for the same chat (19:xxx_thread.v2 used in
-- URLs, 19:xxx@thread.v2 raw). Members were saved with either form, so
-- canonicalize on read/write or lookups silently miss.
local function member_key(chat_id)
  return (chat_id:gsub("_thread%.tacv2$", "@thread.tacv2"):gsub("_thread%.v2$", "@thread.v2"))
end

function M.get_cached_members(chat_id)
  if not chat_id then return nil end
  local ok, j = pcall(M.load, "oneonone_members", MEMBERS_TTL)
  if not ok or type(j) ~= "table" or type(j.members) ~= "table" then return nil end
  local m = j.members[member_key(chat_id)] or j.members[chat_id]
  if type(m) == "table" and #m > 0 then return m end
  return nil
end

function M.save_cached_members(chat_id, members)
  if not chat_id or type(members) ~= "table" or #members == 0 then return end
  local j = nil
  pcall(function() j = M.load("oneonone_members", nil) end)
  if type(j) ~= "table" then j = {} end
  if type(j.members) ~= "table" then j.members = {} end
  j.members[member_key(chat_id)] = members
  M.save("oneonone_members", j)
end

function M.save_me(me)
  local path = vim.fn.stdpath("data") .. "/ms-teams/me.json"
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(me) }, path)
  pcall(vim.fn.system, { "chmod", "600", path })
end

-- Recent watch/notification history for :MSTeamsNotifications. Stored under
-- data (not cache) so it survives cache cleanup; capped to keep the file small.
local function notifications_path()
  local dir = vim.fn.stdpath("data") .. "/ms-teams"
  vim.fn.mkdir(dir, "p")
  return dir .. "/notifications.json"
end

function M.get_notifications(limit)
  local path = notifications_path()
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local ok, j = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(j) ~= "table" or type(j.items) ~= "table" then return {} end
  local items = j.items
  if limit and #items > limit then
    local out = {}
    for i = 1, limit do out[i] = items[i] end
    return out
  end
  return items
end

function M.add_notification(entry)
  if type(entry) ~= "table" then return end
  local path = notifications_path()
  local items = M.get_notifications()
  local key = tostring(entry.chat_id or "") .. "|"
    .. tostring(entry.message_id or entry.created_at or "")
  local out = { entry }
  for _, it in ipairs(items) do
    local k = tostring(it.chat_id or "") .. "|"
      .. tostring(it.message_id or it.created_at or "")
    if k ~= key then table.insert(out, it) end
    if #out >= 200 then break end
  end
  vim.fn.writefile({ vim.json.encode({ items = out }) }, path)
  pcall(vim.fn.system, { "chmod", "600", path })
end

function M.clear_notifications()
  local path = notifications_path()
  if vim.fn.filereadable(path) == 1 then vim.fn.delete(path) end
end

return M
