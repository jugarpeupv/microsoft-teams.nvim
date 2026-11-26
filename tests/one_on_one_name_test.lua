local tmp = vim.fn.tempname() .. "-ms-one-on-one"
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
vim.env.XDG_DATA_HOME = tmp .. "/data"
local src = debug.getinfo(1, "S").source:sub(2)
local root = src:match("^(.*)/tests/[^/]+$") or vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("ms-teams.config").setup()
local cache = require("ms-teams.cache")

local ME = "11111111-1111-1111-1111-111111111111"
local OTHER = "22222222-2222-2222-2222-222222222222"
local ASYNC_OTHER = "33333333-3333-3333-3333-333333333333"
local BOT = "44444444-4444-4444-4444-444444444444"
cache.save("me", { id = ME, displayName = "Me", mail = "me@example.com" })
-- synchronous: already learned from a message/identity
cache.save("user_names", { [OTHER] = "Other Person" })
cache.save("chats", { chats = {
  { id = "19:" .. ME .. "_" .. OTHER .. "@unq.gbl.spaces", chatType = "oneOnOne", topic = "",
    members = { { id = "MCM-self", userId = ME, displayName = "Me", email = "me@example.com" } },
    lastMessagePreview = { createdDateTime = "2026-11-26T10:00:00Z", from = { user = { id = ME, displayName = "Me" } } },
    viewpoint = { lastMessageReadDateTime = "2026-11-26T09:00:00Z" } },
  { id = "19:" .. ME .. "_" .. BOT .. "@unq.gbl.spaces", chatType = "oneOnOne", topic = "",
    members = { { id = "MCM-self", userId = ME, displayName = "Me", email = "me@example.com" } },
    lastMessagePreview = { createdDateTime = "2026-11-26T12:00:00Z" },
    viewpoint = { lastMessageReadDateTime = "2026-11-26T09:00:00Z" } },
  { id = "19:" .. ME .. "_" .. ASYNC_OTHER .. "@unq.gbl.spaces", chatType = "oneOnOne", topic = "",
    members = { { id = "MCM-self", userId = ME, displayName = "Me", email = "me@example.com" } },
    lastMessagePreview = { createdDateTime = "2026-11-26T11:00:00Z", from = { user = { id = ME, displayName = "Me" } } },
    viewpoint = { lastMessageReadDateTime = "2026-11-26T09:00:00Z" } },
} })
local bot_id = "19:" .. ME .. "_" .. BOT .. "@unq.gbl.spaces"
local bot_key = "messages_" .. bot_id:gsub("[^%w%-_:.]", "_"):sub(1, 60)
cache.save(bot_key, { messages = {
  { id = "bot1", messageType = "message", createdDateTime = "2026-11-26T12:00:00Z",
    from = { application = { id = BOT, displayName = "Workflows" } },
    body = { content = "<p>Hola</p>" } },
} })
cache.save("teams_associated", { source = "associated", teams = {} })
cache.save("teams_channels", {})

local graph = require("ms-teams.graph")
graph.list_teams = function(cb) cb({}, nil, {}) end
graph.list_channels = function(_, cb) cb({}, nil, false) end
local user_lookups = {}
graph.get_user_name = function(uid, cb)
  table.insert(user_lookups, uid)
  if uid == ASYNC_OTHER then cb("Async Other", nil) else cb(nil, "not found") end
end
graph.list_chats = function(cb) cb(cache.load("chats").chats, nil) end

local ui = require("ms-teams.ui")
ui.pick_chats()
local buf = vim.api.nvim_get_current_buf()
assert(vim.wait(7000, function()
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  return text:find("Other Person", 1, true) ~= nil
    and text:find("Async Other", 1, true) ~= nil
    and text:find("Workflows", 1, true) ~= nil
end, 50), "oneOnOne names did not resolve")
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(not text:find("Me (You)", 1, true), "self name shown for a 1:1 chat")
assert(text:find("Other Person", 1, true), "cached other name missing")
assert(text:find("Async Other", 1, true), "directory-resolved other name missing")
assert(text:find("Workflows", 1, true), "bot/application sender name missing")
for _, uid in ipairs(user_lookups) do
  assert(uid ~= BOT, "/users was called for an application id")
end
print("ONE_ON_ONE_NAME_OK")
vim.fn.delete(tmp, "rf")
vim.cmd("qa!")
