local tmp = vim.fn.tempname() .. "-ms-channel-test"
vim.fn.delete(tmp, "rf")
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
vim.env.XDG_DATA_HOME = tmp .. "/data"

local root = "/Users/jgp/projects/ms-teams.nvim"
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("ms-teams.config").setup()
local cache = require("ms-teams.cache")

local CH_UNREAD = "19:unread1111111111111111111111111111111111111111111111111111@thread.tacv2"
local CH_SYSTEM = "19:system2222222222222222222222222222222222222222222222222222@thread.tacv2"
local CH_SELF = "19:self33333333333333333333333333333333333333333333333333333@thread.tacv2"
local CH_PROBE = "19:probe4444444444444444444444444444444444444444444444444444@thread.tacv2"
local CH_VARIANT = "19:variant555555555555555555555555555555555555555555555555555@thread.v2"
local TEAM = "team-se"
local TEAM2 = "team-other"

local function safe(id) return id:gsub("[^%w%-_:.]", "_"):sub(1, 60) end

cache.save("me", { id = "me-id", displayName = "Me" })
cache.save("chats", { chats = { {
  id = "chat1", chatType = "oneOnOne", topic = "",
  members = { { id = "other-id", userId = "other-id", displayName = "Other", email = "other@example.com" } },
  lastMessagePreview = { createdDateTime = "2026-11-24T10:00:00Z", from = { user = { id = "other-id", displayName = "Other" } } },
  viewpoint = { lastMessageReadDateTime = "2026-11-24T09:00:00Z" },
} } })
cache.save("teams_associated", { source = "associated", teams = {
  { id = TEAM, displayName = "Engineering Team" },
  { id = TEAM2, displayName = "Other Team" },
} })
cache.save("teams_channels", {
  [TEAM] = {
    { id = CH_UNREAD, displayName = "-General" },
    { id = CH_SYSTEM, displayName = "-SystemOnly" },
    { id = CH_SELF, displayName = "-SelfLatest" },
  },
  [TEAM2] = {
    { id = "19:otherchan@thread.tacv2", displayName = "Other" },
    { id = CH_PROBE, displayName = "-ProbeOnly" },
    { id = CH_VARIANT, displayName = "-Variant" },
  },
})

cache.set_last_read(CH_UNREAD, "2026-11-19T12:09:59Z")
cache.save("messages_" .. safe(CH_UNREAD), { messages = {
  { id = "u1", messageType = "message", createdDateTime = "2026-11-19T08:52:56.505Z",
    from = { user = { id = "other-id", displayName = "Other" } }, body = { content = "older" } },
  { id = "u2", messageType = "message", createdDateTime = "2026-11-19T18:08:49.324Z",
    from = { user = { id = "other-id", displayName = "Other" } }, body = { content = "unread" } },
  { id = "u3", messageType = "unknownFutureValue", createdDateTime = "2026-11-20T07:07:00.527Z",
    eventDetail = {}, body = { content = "<systemEventMessage/>" } },
} })

cache.set_last_read(CH_SYSTEM, "2026-11-19T12:09:59Z")
cache.save("messages_" .. safe(CH_SYSTEM), { messages = {
  { id = "s1", messageType = "unknownFutureValue", createdDateTime = "2026-11-20T07:07:00.527Z",
    eventDetail = {}, body = { content = "<systemEventMessage/>" } },
} })

cache.set_last_read(CH_SELF, "2026-11-19T12:09:59Z")
cache.save("messages_" .. safe(CH_SELF), { messages = {
  { id = "a1", messageType = "message", createdDateTime = "2026-11-19T18:00:00Z",
    from = { user = { id = "other-id", displayName = "Other" } }, body = { content = "unread earlier" } },
  { id = "a2", messageType = "message", createdDateTime = "2026-11-19T19:00:00Z",
    from = { user = { id = "me-id", displayName = "Me" } }, body = { content = "mine" } },
} })

-- read reference stored under the historical id variant, messages under the
-- current one: variant-aware lookup must still see the unread message
cache.set_last_read(CH_VARIANT:gsub("@thread%.v2$", "@thread.tacv2"), "2026-11-19T12:09:59Z")
cache.save("messages_" .. safe(CH_VARIANT), { messages = {
  { id = "v1", messageType = "message", createdDateTime = "2026-11-19T18:00:00Z",
    from = { user = { id = "other-id", displayName = "Other" } }, body = { content = "unread" } },
} })

-- no last_read: only the probe can discover the newer message
cache.save("messages_" .. safe(CH_PROBE), { messages = {
  { id = "p1", messageType = "message", createdDateTime = "2026-11-18T10:00:00Z",
    from = { user = { id = "other-id", displayName = "Other" } }, body = { content = "seen before" } },
} })

local graph = require("ms-teams.graph")
graph.list_teams = function(cb) cb(cache.load("teams_associated").teams, nil, { source = "associated" }) end
graph.list_channels = function(team_id, cb) cb(cache.load("teams_channels")[team_id] or {}, nil, false) end
graph.list_channel_messages = function(_team_id, channel_id, cb)
  local msgs = {}
  if channel_id == CH_PROBE then
    msgs = {
      { id = "p2", messageType = "message", createdDateTime = "2026-11-24T08:00:00Z",
        from = { user = { id = "other-id", displayName = "Other" } }, body = { content = "new" } },
      { id = "p3", messageType = "unknownFutureValue", createdDateTime = "2026-11-24T09:00:00Z",
        eventDetail = {}, body = { content = "<systemEventMessage/>" } },
    }
  end
  vim.schedule(function() cb(msgs, nil, nil) end)
end

local ui = require("ms-teams.ui")
local function highlighted_lines(buf)
  local ns = vim.api.nvim_create_namespace("ms_teams_unread")
  local names = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    table.insert(names, vim.api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)[1] or "")
  end
  return names
end
local function any_contains(tbl, needle)
  for _, l in ipairs(tbl) do if l:find(needle, 1, true) then return true end end
  return false
end
local function any_prefix(tbl, prefix)
  for _, l in ipairs(tbl) do if l:sub(1, #prefix) == prefix then return true end end
  return false
end

ui.pick_chats()
local chats_buf = vim.api.nvim_get_current_buf()
local function chan_map_now()
  local ok, map = pcall(vim.api.nvim_buf_get_var, chats_buf, "ms_teams_channel_unread")
  return ok and map or nil
end
assert(vim.wait(6000, function()
  local map = chan_map_now()
  return map and map[CH_UNREAD] ~= nil
end, 50), "chat list did not render channels in time")
local chan_map = chan_map_now()
assert(chan_map[CH_UNREAD] == true, "real unread channel not marked unread")
assert(chan_map[CH_SYSTEM] == false, "system-only channel was marked unread")
assert(chan_map[CH_SELF] == true, "earlier-other channel was not marked unread")
assert(chan_map[CH_VARIANT] == true, "id-variant channel was not marked unread")

assert(vim.wait(8000, function()
  local m = chan_map_now()
  return m and m[CH_PROBE] == true
end, 50), "probe-only channel was not marked unread after the background probe")
chan_map = chan_map_now()
assert(chan_map[CH_PROBE] == true, "probe-only channel not unread")
assert(chan_map[CH_SYSTEM] == false, "system-only channel was marked unread after probe")

local hl = highlighted_lines(chats_buf)
assert(any_contains(hl, "-General"), "unread channel not highlighted in chat list")
assert(not any_prefix(hl, "## "), "team header highlighted in chat list")
assert(any_contains(hl, "-ProbeOnly"), "probe-only unread channel not highlighted in chat list")
assert(any_contains(hl, "-Variant"), "id-variant unread channel not highlighted in chat list")
assert(not any_contains(hl, "SystemOnly"), "system-only channel highlighted in chat list")

ui.pick_teams()
local teams_buf = vim.api.nvim_get_current_buf()
assert(vim.wait(3000, function()
  local ok, t = pcall(vim.api.nvim_buf_get_var, teams_buf, "ms_teams_teams")
  return ok and type(t) == "table" and #t > 0
end, 50), "teams list did not render in time")
local thl = highlighted_lines(teams_buf)
assert(any_contains(thl, "-General"), "unread channel not highlighted in :MSTeamsTeams")
assert(not any_prefix(thl, "## "), "team header highlighted in :MSTeamsTeams")
assert(not any_contains(thl, "SystemOnly"), "system-only channel highlighted in :MSTeamsTeams")
print("CHANNEL_UNREAD_OK")
vim.fn.delete(tmp, "rf")
vim.cmd("qa!")
