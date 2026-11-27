local tmp = vim.fn.tempname() .. "-ms-adaptive"
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
vim.env.XDG_DATA_HOME = tmp .. "/data"
local src = debug.getinfo(1, "S").source:sub(2)
local root = src:match("^(.*)/tests/[^/]+$") or vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("ms-teams.config").setup()
local cache = require("ms-teams.cache")
cache.save("me", { id = "me-id", displayName = "Me" })
local card = {
  type = "AdaptiveCard", version = "1.4",
  body = {
    { type = "TextBlock", size = "large", weight = "bolder", wrap = true,
      text = "🎉 ¡Hoy es el día de la Smart Pill: Liferay & IA!" },
    { type = "TextBlock", text = "🕒 No te lo pierdas" },
    { type = "TextBlock", text = "El evento comienza hoy a las 13:30" },
    { type = "TextBlock", text = "👨‍💻Ponentes: Daniel García García" },
    { type = "Container", items = {
      { type = "TextBlock", text = "Descripción de la sesión" },
    } },
    { type = "FactSet", facts = {
      { title = "Sala", value = "Online" },
      { title = "Hora", value = "13:30" },
    } },
  },
  actions = {
    { type = "Action.OpenUrl", title = "🔗 Unirme al evento", url = "https://example.com/join" },
  },
}
local MSG = {
  id = "m-card", messageType = "message", createdDateTime = "2026-11-27T08:00:00Z",
  from = { user = { id = "bot", displayName = "svc_TeamsShr" } },
  body = { content = 'Hola equipo <at id="0">-Smart Pills</at> 🎉 <br>\n<attachment id="x"></attachment>' },
  attachments = { { id = "x", contentType = "application/vnd.microsoft.card.adaptive", content = vim.json.encode(card) } },
}
local graph = require("ms-teams.graph")
graph.list_messages_until_read = function(_, _, cb) cb({ MSG }, nil, nil) end
graph.list_messages = function(_, cb) cb({ MSG }, nil, nil) end
graph.get_chat = function(id, cb) cb({ id = id, chatType = "group", topic = "Card Test", members = {} }, nil) end
graph.get_user_name = function(_, cb) cb(nil, "not found") end
local ui = require("ms-teams.ui")
ui.show_messages({ id = "19:cardtest@thread.v2", chatType = "group", topic = "Card Test", members = {} }, "current")
local buf = vim.api.nvim_get_current_buf()
assert(vim.wait(5000, function()
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  local t = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  return t:find("Smart Pill", 1, true) ~= nil
end, 50), "card not rendered")
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
for _, needle in ipairs({
  "¡Hoy es el día de la Smart Pill: Liferay & IA!",
  "No te lo pierdas",
  "El evento comienza hoy a las 13:30",
  "Ponentes: Daniel García García",
  "Descripción de la sesión",
  "Sala", "13:30",
  "[🔗 Unirme al evento](https://example.com/join)",
}) do
  assert(text:find(needle, 1, true), "missing: " .. needle)
end
assert(not text:find("[Attachment: application/vnd.microsoft.card.adaptive]", 1, true), "opaque adaptive placeholder still present")
print("ADAPTIVE_OK")
vim.fn.delete(tmp, "rf")
vim.cmd("qa!")
