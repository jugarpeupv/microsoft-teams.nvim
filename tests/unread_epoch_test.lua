local tmp = vim.fn.tempname() .. "-ms-unread-epoch"
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
vim.env.XDG_DATA_HOME = tmp .. "/data"
local src = debug.getinfo(1, "S").source:sub(2)
local root = src:match("^(.*)/tests/[^/]+$") or vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("ms-teams.config").setup()
local cache = require("ms-teams.cache")
local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
local me = "aaaaaaaa-1111-1111-1111-111111111111"
local other = "bbbbbbbb-2222-2222-2222-222222222222"
cache.save("me", { id = me, displayName = "Me" })
local function chat(id, topic, preview, chat_type)
  return {
    id = id, chatType = chat_type or "group", topic = topic,
    viewpoint = { lastMessageReadDateTime = "0001-01-01T00:00:00Z" },
    lastMessagePreview = preview,
  }
end
local function from_user(id, name)
  return { user = { id = id, displayName = name } }
end
cache.save("chats", { chats = {
  chat("19:recent@thread.v2", "RecentOther", {
    messageType = "message", createdDateTime = now, from = from_user(other, "Other"),
  }),
  chat("19:old@thread.v2", "OldOther", {
    messageType = "message", createdDateTime = "2020-01-01T00:00:00Z", from = from_user(other, "Other"),
  }),
  chat("19:self@thread.v2", "RecentSelf", {
    messageType = "message", createdDateTime = now, from = from_user(me, "Me"),
  }),
  chat("19:system@thread.v2", "RecentSystem", {
    messageType = "unknownFutureValue", eventDetail = {}, createdDateTime = now,
  }),
  chat("19:meeting_test@thread.v2", "MeetingChat", {
    messageType = "message", createdDateTime = now, from = from_user(other, "Other"),
  }, "meeting"),
} })
cache.save("teams_associated", { source = "associated", teams = {} })
cache.save("teams_channels", {})
local graph = require("ms-teams.graph")
graph.list_teams = function(cb) cb({}, nil, {}) end
graph.list_channels = function(_, cb) cb({}, nil, false) end
graph.get_user_name = function(_, cb) cb(nil, "not found") end
local ui = require("ms-teams.ui")
ui.pick_chats()
local buf = vim.api.nvim_get_current_buf()
assert(vim.wait(5000, function()
  local ok, all = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_all_chats")
  return ok and type(all) == "table" and #all == 5
end, 50), "chat list did not render")
local ns = vim.api.nvim_create_namespace("ms_teams_unread")
local lit = {}
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do
  local l = vim.api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)[1] or ""
  table.insert(lit, l)
end
local text = table.concat(lit, "\n")
assert(text:find("RecentOther", 1, true), "recent other message not unread")
assert(not text:find("OldOther", 1, true), "old epoch chat marked unread")
assert(not text:find("RecentSelf", 1, true), "self message marked unread")
assert(not text:find("RecentSystem", 1, true), "system event marked unread")
assert(text:find("MeetingChat", 1, true), "meeting chat not shown/highlighted")
print("UNREAD_EPOCH_OK")
vim.fn.delete(tmp, "rf")
vim.cmd("qa!")
