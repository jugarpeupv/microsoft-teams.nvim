-- keycap reactions (1️⃣ = digit + VS16 + U+20E3) break the terminal cell
-- grid, so the display layer normalizes them to circled digits (①②…).
-- Fully synthetic messages: no fixtures, no cache, no network.
local src = debug.getinfo(1, "S").source:sub(2)
local root = src:match("^(.*)/tests/[^/]+$")
if not root or root == "" then root = "." end
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local ok, ui = pcall(require, "ms-teams.ui")
assert(ok, tostring(ui))

local function decl_line(name)
  for i, l in ipairs(vim.fn.readfile(root .. "/lua/ms-teams/ui.lua")) do
    if l:find("local function " .. name .. "%(") then return i end
  end
  error("decl not found: " .. name)
end

local found = {}
local function scan(fn, depth, seen)
  if depth > 8 or seen[fn] then return end
  seen[fn] = true
  local i = 1
  while true do
    local n, v = debug.getupvalue(fn, i)
    if not n then break end
    if type(v) == "function" then
      local info = debug.getinfo(v, "S")
      if info and info.source:find("ui.lua", 1, true) then
        found[info.linedefined] = found[info.linedefined] or v
      end
      scan(v, depth + 1, seen)
    end
    i = i + 1
  end
end
for _, v in pairs(ui) do
  if type(v) == "function" then scan(v, 0, {}) end
end
local build = found[decl_line("build_message_lines")]
assert(build, "build_message_lines not reachable")
print("OK build_message_lines found via upvalues")

local chat = {}
local KC1 = "1️⃣" -- digit + U+FE0F + U+20E3
local KC2 = "2️⃣"
local KC3_NO_VS = "3" .. "\226\131\163" -- keycap without the VS16 selector
local E20E3 = "\226\131\163" -- raw combining enclosing keycap must never leak

local function reacted(uid, name, rt, label)
  return { displayName = label, reactionType = rt, user = { userId = uid, displayName = name } }
end

local msg = {
  id = "syn-keycap-1",
  from = { user = { displayName = "Synthetic Author" } },
  createdDateTime = "2026-01-05T10:00:00Z",
  body = { content = "<p>Vote<br>- Monday =&gt; " .. KC1 .. "<br>- Tuesday =&gt; " .. KC2 .. "</p>" },
  reactions = {
    reacted("syn-uid-1", "Test Voter One", KC1, "Keycap one"),
    reacted("syn-uid-2", "Test Voter Two", KC1, "Keycap one"),
    reacted("syn-uid-3", "Test Voter Three", KC2, "Keycap two"),
    reacted("syn-uid-4", "Test Voter Four", "❤️", nil),
  },
}

local function compact_line(res)
  for _, l in ipairs(res.lines) do
    local c = l:match("^  %[(reactions: .*)%]$")
    if c then return c end
  end
  return nil
end

local function assert_no_raw_keycap(lines, where)
  for _, l in ipairs(lines) do
    assert(not l:find(E20E3, 1, true), "raw U+20E3 leaked in " .. where .. ": " .. l)
  end
end

-- 1) body text: keycaps become circled digits
local res = assert(build(msg, chat))
local body_txt = table.concat(res.lines, "\n")
print("--- keycap body ---")
for _, l in ipairs(res.lines) do print("  " .. l) end
assert(body_txt:find("Monday => ①", 1, true), "body Monday not normalized:\n" .. body_txt)
assert(body_txt:find("Tuesday => ②", 1, true), "body Tuesday not normalized:\n" .. body_txt)
assert_no_raw_keycap(res.lines, "body")
print("OK body keycaps normalized to circled digits")

-- 2) compact line: normalized groups, inline name still works
local c = compact_line(res)
print("keycap compact -> " .. tostring(c))
assert(c == "reactions: ① 2 ② 1 Test Voter Three ❤️ 1 Test Voter Four",
  "unexpected compact: " .. tostring(c))
print("OK compact line uses circled digits")

-- 3) keycap without VS16 normalizes too (body + compact)
local msg2 = {
  id = "syn-keycap-2",
  from = { user = { displayName = "Synthetic Author" } },
  createdDateTime = "2026-01-05T11:00:00Z",
  body = { content = "<p>Vote<br>- Wednesday =&gt; " .. KC3_NO_VS .. "</p>" },
  reactions = { reacted("syn-uid-5", "Test Voter Five", KC3_NO_VS, "Keycap three") },
}
local res2 = assert(build(msg2, chat))
local body2 = table.concat(res2.lines, "\n")
assert(body2:find("Wednesday => ③", 1, true), "no-VS16 body not normalized:\n" .. body2)
local c2 = compact_line(res2)
assert(c2 == "reactions: ③ 1 Test Voter Five", "no-VS16 compact wrong: " .. tostring(c2))
assert_no_raw_keycap(res2.lines, "no-VS16 message")
print("OK keycap without VS16 normalizes too")

-- 4) gr detail: keycap headers carry the Graph displayName, plain emoji don't
local dbuf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_var(dbuf, "ms_teams_id_to_lnum", { [msg.id] = 4 })
vim.api.nvim_buf_set_var(dbuf, "ms_teams_raw_msgs", { msg })
local ph = {}
for i = 1, 8 do ph[i] = "" end
vim.api.nvim_buf_set_lines(dbuf, 0, -1, false, ph)
vim.api.nvim_set_current_buf(dbuf)
vim.api.nvim_win_set_cursor(0, { 6, 0 })
ui.show_reactions(dbuf, chat)
local out = vim.api.nvim_buf_get_lines(0, 0, -1, false)
print("--- keycap detail ---")
for _, l in ipairs(out) do print("  " .. l) end
local txt = table.concat(out, "\n")
local function has_exact_line(want)
  for _, l in ipairs(out) do if l == want then return true end end
  return false
end
assert((out[1] or ""):find("^# Reactions"), "title missing")
assert(has_exact_line("## ① ×2 — Keycap one"), "keycap-one header wrong")
assert(has_exact_line("## ② ×1 — Keycap two"), "keycap-two header wrong")
assert(has_exact_line("## ❤️ ×1"), "plain emoji header must stay suffix-free")
assert(txt:find("- Test Voter One", 1, true), "voter one missing")
assert(txt:find("- Test Voter Two", 1, true), "voter two missing")
assert(txt:find("- Test Voter Four", 1, true), "voter four missing")
assert(not txt:find("? (", 1, true), "unresolved placeholder should be gone")
assert(txt:find("Monday => ①", 1, true), "detail body not normalized")
assert_no_raw_keycap(out, "detail")
print("OK detail headers name the keycap groups")

-- 5) bot/app sender (Power Automate "Workflows"): application displayName
-- is used instead of "unknown", in the message header and detail title
local msg3 = {
  id = "syn-keycap-3",
  from = { application = { displayName = "Workflows", applicationIdentityType = "bot" } },
  createdDateTime = "2026-01-05T12:00:00Z",
  body = { content = "<p>Weekly vote<br>- Monday =&gt; " .. KC1 .. "</p>" },
}
local res3 = assert(build(msg3, chat))
print("--- app-sender header ---")
print("  " .. (res3.lines[1] or ""))
assert((res3.lines[1] or ""):find("**Workflows** (", 1, true),
  "header should name the app sender: " .. tostring(res3.lines[1]))
assert(not (res3.lines[1] or ""):find("unknown", 1, true), "unknown leaked into app-sender header")
local dbuf3 = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_var(dbuf3, "ms_teams_id_to_lnum", { [msg3.id] = 4 })
vim.api.nvim_buf_set_var(dbuf3, "ms_teams_raw_msgs", { msg3 })
local ph3 = {}
for i = 1, 8 do ph3[i] = "" end
vim.api.nvim_buf_set_lines(dbuf3, 0, -1, false, ph3)
vim.api.nvim_set_current_buf(dbuf3)
vim.api.nvim_win_set_cursor(0, { 6, 0 })
ui.show_reactions(dbuf3, chat)
local out3 = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert((out3[1] or ""):find("**Workflows**", 1, true),
  "detail title should name the app sender: " .. tostring(out3[1]))
print("OK app sender renders as Workflows, not unknown")

print("ALL_OK")
vim.cmd("qa!")
