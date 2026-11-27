local tmp = vim.fn.tempname() .. "-ms-chat-order"
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
vim.env.XDG_DATA_HOME = tmp .. "/data"
local src = debug.getinfo(1, "S").source:sub(2)
local root = src:match("^(.*)/tests/[^/]+$") or vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("ms-teams.config").setup()
local cache = require("ms-teams.cache")
local me = "aaaaaaaa-1111-1111-1111-111111111111"
local other = "bbbbbbbb-2222-2222-2222-222222222222"
cache.save("me", { id = me, displayName = "Me" })
local function chat(id, topic, preview_date, read_date)
  return {
    id = id, chatType = "group", topic = topic,
    viewpoint = { lastMessageReadDateTime = read_date },
    lastMessagePreview = {
      messageType = "message", createdDateTime = preview_date,
      from = { user = { id = other, displayName = "Other" } },
    },
  }
end
cache.save("chats", { chats = {
  chat("19:newread@thread.v2", "NewRead", "2026-11-26T12:00:00Z", "2026-11-26T13:00:00Z"),
  chat("19:oldunread@thread.v2", "OldUnread", "2026-01-01T12:00:00Z", "2020-01-01T12:00:00Z"),
  chat("19:newunread@thread.v2", "NewUnread", "2026-11-26T13:00:00Z", "2020-01-01T12:00:00Z"),
  chat("19:oldread@thread.v2", "OldRead", "2025-01-01T12:00:00Z", "2026-11-26T14:00:00Z"),
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
  return ok and type(all) == "table" and #all == 4
end, 50), "chat list did not render")
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local pos = {}
for i, l in ipairs(lines) do
  for _, name in ipairs({ "NewUnread", "OldUnread", "NewRead", "OldRead" }) do
    if l:find(name, 1, true) then pos[name] = i end
  end
end
assert(pos.NewUnread and pos.OldUnread and pos.NewRead and pos.OldRead, "chat rows missing")
assert(pos.NewUnread < pos.OldUnread, "unread chats not sorted by recency")
assert(pos.OldUnread < pos.NewRead, "unread chat not moved above newer read chat")
assert(pos.NewRead < pos.OldRead, "read chats not sorted by recency")

-- mr/mu updates must reorder without reopening: mark NewRead unread and
-- expect it to move into the unread group above OldUnread.
ui.update_chat_list_unread_state("19:newread@thread.v2", true)
assert(vim.wait(6000, function()
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  local p = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find("NewRead", 1, true) then p.NewRead = i end
    if l:find("OldUnread", 1, true) then p.OldUnread = i end
  end
  return p.NewRead and p.OldUnread and p.NewRead < p.OldUnread
end, 50), "unread-first order was not refreshed after mark-unread")
print("CHAT_ORDER_OK")
vim.fn.delete(tmp, "rf")
vim.cmd("qa!")
