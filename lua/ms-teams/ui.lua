local graph = require("ms-teams.graph")

local M = {}

local function nv(v)
  if v == vim.NIL then return nil end
  return v
end

-- end column for whole-line highlights: explicit text length, NOT -1. A -1
-- end normalizes to the next line start, so clearing an adjacent line kills
-- the mark by range overlap (e.g. mr on Random cleared Core's highlight).
local function eol_col(buf, lnum)
  local ok, l = pcall(vim.api.nvim_buf_get_lines, buf, lnum - 1, lnum, false)
  if ok and l and l[1] then return #(l[1]) end
  return 0
end

-- circuit breaker: after a Graph 429 on tab resolution, stop trying for a while
local tab_throttle_until = 0

-- tabReference attachments carry {"tabId": "..."} JSON in content; the file
-- URL is resolved via GET /chats/{id}/tabs -> configuration.contentUrl
local function url_decode(s)
  if not s or s == "" then return "" end
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
-- decode repeatedly until stable (handles double-encoded %2520 etc)
local function fully_decode(s)
  local prev, cur = nil, s or ""
  while cur ~= prev do
    prev = cur
    cur = url_decode(cur)
  end
  return cur
end
-- Teams tab launcher URLs (m365.cloud.microsoft/launch/...) embed the real
-- file in subEntityId.objectUrl (often double-encoded); unwrap to direct URL.
-- Also normalizes any double-encoded (%25...) URL to fixpoint.
local function unwrap_tab_url(url)
  if not url or url == "" then return url end
  local sub = url:match("[?&]subEntityId=([^&]+)")
  if sub then
    local decoded = url_decode(url_decode(sub))
    local obj = decoded:match('"objectUrl"%s*:%s*"([^"]+)"')
    if obj and obj ~= "" then url = obj end
  end
  if url:find("%%25") then
    local prev, cur = nil, url
    while cur ~= prev do
      prev = cur
      cur = url_decode(cur)
    end
    url = cur
  end
  return url
end
local function parse_tab_reference(content)
  if not content or content == "" then return nil, nil end
  local ok, j = pcall(vim.json.decode, content)
  if ok and type(j) == "table" then
    local tab_id = j.tabId or j.tabid or j.tab_id or j.id
    local tab_name = j.tabName or j.tabname or j.tab_name or j.name or j.displayName
    if tab_id == vim.NIL then tab_id = nil end
    if tab_name == vim.NIL then tab_name = nil end
    if tab_id then return tab_id, tab_name end
  end
  -- fallback: raw content may embed a GUID and/or "tabName":"..."
  local guid = content:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)")
  local tname = content:match('"tab[Nn]ame"%s*:%s*"([^"]+)"')
  return guid, tname
end
-- extract SharePoint drive/item ids from a Teams launcher websiteUrl
-- (subEntityId JSON carries driveId/docId)
local function parse_drive_ids(website_url)
  if not website_url or website_url == "" then return nil, nil end
  local sub = website_url:match("[?&]subEntityId=([^&]+)")
  if not sub then return nil, nil end
  local decoded = url_decode(url_decode(sub))
  local drive = decoded:match('"driveId"%s*:%s*"([^"]+)"')
  local doc = decoded:match('"docId"%s*:%s*"([^"]+)"')
  if drive == "" then drive = nil end
  if doc == "" then doc = nil end
  return drive, doc
end

local function get_unread_hl_group()
  local cfg = require("ms-teams.config").options
  if cfg and cfg.highlights and cfg.highlights.unread and cfg.highlights.unread ~= "" then
    return cfg.highlights.unread
  end
  return "DiagnosticInfo"
end

local function get_chat_type_icon(chat)
  local cfg = require("ms-teams.config").options
  if not cfg or not cfg.icons or not cfg.icons.enabled then return "" end
  local ct = nv(chat.chatType) or "default"
  local icons = cfg.icons.chatType or {}
  -- meeting takes precedence even if also groupChat
  if ct == "meeting" then return icons.meeting or "" end
  return icons[ct] or icons.default or ""
end

local function is_from_me(fromUser)
  if not fromUser or fromUser == vim.NIL then return false end
  local fid = nv(fromUser.id)
  local dname = nv(fromUser.displayName)
  -- dynamic me: from token or cache, fallback to not hardcoded
  local me_id, me_name
  local ok, cache_data = pcall(require("ms-teams.cache").load, "me")
  if ok and cache_data and cache_data.id then
    me_id = cache_data.id
    me_name = cache_data.displayName
  else
    -- fallback: try to read from token file (no hardcode)
    me_id = vim.g.ms_teams_me_id
    me_name = vim.g.ms_teams_me_name
  end
  if fid and me_id and fid == me_id then return true end
  if dname and me_name and dname == me_name then return true end
  -- if no cache, check isOwned flag
  return false
end

local function get_other_user_id(chat)
  if nv(chat.chatType) ~= "oneOnOne" then return nil end
  local members = nv(chat.members)
  if members and type(members) == "table" and #members > 0 then
    local me = nil
    local ok, cache_data = pcall(require("ms-teams.cache").load, "me")
    if ok and cache_data and cache_data.id then me = cache_data.id end
    if not me then me = vim.g.ms_teams_me_id end
    for _, m in ipairs(members) do
      if m ~= vim.NIL then
        local uid = nv(m.userId) or nv(m.id)
        if uid and uid ~= me then return uid end
        local dname = nv(m.displayName)
        local me_name = cache_data and cache_data.displayName or vim.g.ms_teams_me_name
        if dname and me_name and dname ~= me_name then
          if uid and uid:match("^%x%x%x%x%x%x%x%x%-%x") then return uid end
        end
      end
    end
  end
  -- fallback: use lastMessagePreview.from when members not yet enriched (list_chats without $expand=members)
  local preview = nv(chat.lastMessagePreview)
  if preview then
    local from = nv(preview.from) and nv(nv(preview.from).user)
    if from and not is_from_me(from) then
      local fid = nv(from.id)
      if fid and fid:match("^%x%x%x%x%x%x%x%x%-%x") then return fid end
    end
  end
  return nil
end

local function is_message_unread(msg, chat)
  local cache = require("ms-teams.cache")
  local override = cache.get_last_read(nv(chat.id))
  local lr = override
  if not lr then
    local vp = nv(chat.viewpoint)
    lr = vp and nv(vp.lastMessageReadDateTime)
  end
  local ct = nv(msg.createdDateTime)
  if not lr or not ct then return false end
  if ct <= lr then return false end
  local from = nv(msg.from) and nv(nv(msg.from).user)
  if from and is_from_me(from) then return false end
  return true
end

-- newest message date previously seen for a channel, across id variants
-- (@thread.v2 vs @thread.tacv2 historically produced different cache keys)
local function channel_seen_newest(cid)
  if not cid or cid == "" then return nil end
  local ids = { cid }
  if cid:sub(-13) == "@thread.tacv2" then
    table.insert(ids, cid:sub(1, -14) .. "@thread.v2")
  elseif cid:sub(-10) == "@thread.v2" then
    table.insert(ids, cid:sub(1, -11) .. "@thread.tacv2")
  end
  local cache = require("ms-teams.cache")
  local newest = nil
  local seen_keys = {}
  for _, id in ipairs(ids) do
    local key = "messages_" .. id:gsub("[^%w%-_:.]", "_"):sub(1, 60)
    if not seen_keys[key] then
      seen_keys[key] = true
      local okc, cc = pcall(cache.load, key)
      if okc and cc and cc.messages then
        for _, m in ipairs(cc.messages) do
          if m ~= vim.NIL then
            local dt = nv(m.createdDateTime) or ""
            if dt ~= "" and (not newest or dt > newest) then newest = dt end
          end
        end
      end
    end
  end
  return newest
end

local function has_unread(chat)
  local cache = require("ms-teams.cache")
  local override = cache.get_last_read(nv(chat.id))
  local lr = override
  if not lr then
    local vp = nv(chat.viewpoint)
    lr = vp and nv(vp.lastMessageReadDateTime)
  end
  local preview = nv(chat.lastMessagePreview)
  local lu = preview and nv(preview.createdDateTime) or nv(chat.lastUpdatedDateTime)
  if not lu then return false end
  if lr then
    if lu <= lr then return false end
  else
    -- no lastRead: need to be conservative; check cached messages first
    if not preview then return false end
    local pFrom = preview and nv(preview.from) and nv(nv(preview.from).user)
    if pFrom and is_from_me(pFrom) then return false end
    if preview and nv(preview.isOwned) == true then return false end
    -- if sender unknown (previewFrom nil), don't assume unread; check cached messages
    if not pFrom then
      local ok, cached = pcall(require("ms-teams.cache").load, "messages_" .. (nv(chat.id) or ""):gsub("[^%w%-_:.]", "_"):sub(1,60))
      if ok and cached and cached.messages then
        for _, m in ipairs(cached.messages) do
          if m ~= vim.NIL and is_message_unread(m, chat) then return true end
        end
      end
      return false
    end
    return true
  end
  if preview then
    local pFrom = nv(preview.from) and nv(nv(preview.from).user)
    if pFrom and is_from_me(pFrom) then
      -- last is from self, check if any earlier message is unread via cache
      local ok, cached = pcall(require("ms-teams.cache").load, "messages_" .. (nv(chat.id) or ""):gsub("[^%w%-_:.]", "_"):sub(1,60))
      if ok and cached and cached.messages then
        for _, m in ipairs(cached.messages) do
          if m ~= vim.NIL and is_message_unread(m, chat) then return true end
        end
      end
      return false
    end
    if nv(preview.isOwned) == true then return false end
  end
  return true
end

local function get_me()
  local ok, cache_data = pcall(require("ms-teams.cache").load, "me")
  if ok and cache_data and cache_data.displayName then return cache_data end
  -- fallback: try to get from token file
  local me_name = vim.g.ms_teams_me_name
  local me_id = vim.g.ms_teams_me_id
  if me_name and me_id then return {displayName=me_name, id=me_id} end
  return nil
end

local function get_last_read_iso(chat)
  local cache = require("ms-teams.cache")
  local override = cache.get_last_read(nv(chat.id))
  if override then return override end
  local vp = nv(chat.viewpoint)
  return vp and nv(vp.lastMessageReadDateTime)
end

-- coalesce rapid re-renders (tab resolve + search + watch) into one per tick
local pending_detail_renders = {}
local detail_loading_ns = vim.api.nvim_create_namespace("ms_teams_loading")
-- search in chat (Option B: server-side) helpers
local search_ns = vim.api.nvim_create_namespace("ms_teams_search_hl")
local function is_smart_case_sensitive(q)
  return q:find("%u") ~= nil
end
local function extract_message_plain(m)
  if not m or m == vim.NIL then return "" end
  local parts = {}
  local from = nv(m.from) and nv(m.from.user) and nv(m.from.user.displayName)
  if from and from ~= "" then table.insert(parts, from) end
  local body = nv(m.body) and nv(m.body.content) or ""
  if body and body ~= "" and body ~= vim.NIL then
    -- strip html similar to build_message_lines but lightweight
    body = body:gsub("<[^>]+>", " ")
    body = body:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    body = body:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if body ~= "" then table.insert(parts, body) end
  end
  -- include file names from attachments
  local atts = nv(m.attachments)
  if atts and type(atts) == "table" then
    for _, a in ipairs(atts) do
      if a ~= vim.NIL then
        local n = nv(a.name)
        if n and n ~= "" then table.insert(parts, n) end
      end
    end
  end
  return table.concat(parts, " ")
end
local function make_snippet(plain, q)
  if not plain or plain == "" or not q or q == "" then return plain or "", nil, nil end
  local sensitive = is_smart_case_sensitive(q)
  local hay = sensitive and plain or plain:lower()
  local needle = sensitive and q or q:lower()
  local s, e = hay:find(needle, 1, true)
  if not s then return plain:sub(1, 120) .. (#plain > 120 and "..." or ""), nil, nil end
  local ctx = 40
  local from = math.max(1, s - ctx)
  local to = math.min(#plain, e + ctx)
  local snippet = plain:sub(from, to)
  if from > 1 then snippet = "..." .. snippet end
  if to < #plain then snippet = snippet .. "..." end
  snippet = snippet:gsub("\n", " "):gsub("%s+", " ")
  local hl_s = s - from + 1 + (from > 1 and 3 or 0)
  local hl_e = hl_s + #q - 1
  return snippet, hl_s, hl_e
end

local function format_chat(chat)
  if nv(chat.id) == "48:notes" then
    local me = get_me()
    local name = me and me.displayName or "You"
    return name .. " (You) [Notes]"
  end
  local topic = nv(chat.topic)
  if topic and topic ~= "" then return topic end
  if nv(chat.chatType) == "oneOnOne" then
    local members = nv(chat.members)
    if members and type(members) == "table" then
      local valid = {}
      for _, m in ipairs(members) do if m ~= vim.NIL and nv(m.displayName) then table.insert(valid, m) end end
      if #valid == 1 then
        local n = nv(valid[1].displayName) or "oneOnOne"
        local email = nv(valid[1].email) or ""
        local short = nv(chat.id) and nv(chat.id):sub(1,8) or ""
        -- Graph con $expand=members y limit=500 trunca a 1 miembro en muchos oneOnOne
        -- si el único miembro coincide con el usuario actual autenticado (get_me), mostramos shortId
        -- y el plugin lo enriquecerá async vía GET /chats/{id}
        local me_tmp2 = get_me()
        local me_n2 = me_tmp2 and me_tmp2.displayName
        local me_mail = me_tmp2 and (me_tmp2.mail or me_tmp2.userPrincipalName)
        if n == me_n2 or (me_mail and email ~= "" and email:lower() == me_mail:lower()) then
          if me_mail and email ~= "" and email:lower() == me_mail:lower() then
            -- si ya enriquecido o mail coincide, es self chat; si no, es incompleto -> hint
            return n .. " (You) [" .. short .. "]"
          else
            return n .. " [" .. short .. "]"
          end
        end
        return n .. " (You?) [" .. short .. "]"
      end
      if #valid == 2 then
        for _, m in ipairs(valid) do
          local name = nv(m.displayName)
          local me = get_me(); local me_name = me and me.displayName; if name and name ~= "" and (not me_name or name ~= me_name) then return name end
        end
      end
      -- fallback: lista miembros sin ti
      local others = {}
      for _, m in ipairs(valid) do
        local name = nv(m.displayName)
        local me2 = get_me(); local me_n2 = me2 and me2.displayName; if name and (not me_n2 or name ~= me_n2) then table.insert(others, name) end
      end
      if #others > 0 then return table.concat(others, ", ") end
      for _, m in ipairs(valid) do
        local n = nv(m.displayName)
        if n and n ~= "" then return n end
      end
    end
    return "oneOnOne [" .. (nv(chat.id) and nv(chat.id):sub(1,8) or "") .. "]"
  end
  return (nv(chat.chatType) or "chat") .. (nv(chat.topic) and nv(chat.topic)~="" and (": "..nv(chat.topic)) or "")
end

local date_cache = {}

local function format_date(iso)
  if not iso or iso == "" then return "" end
  if date_cache[iso] then return date_cache[iso] end

  local y, m, d, h, min, s = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then
    date_cache[iso] = iso
    return iso
  end

  local now = os.time()
  local local_t = os.date("*t", now)
  local utc_t = os.date("!*t", now)
  local tz_offset = os.difftime(os.time(local_t), os.time(utc_t))

  local t_as_local = os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(min),
    sec = tonumber(s),
  })

  local true_local_epoch = t_as_local + tz_offset
  local formatted = os.date("%H:%M %d/%m/%Y", true_local_epoch)
  date_cache[iso] = formatted
  return formatted
end

local function set_listed_scratch(buf, name)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "buflisted", true)
  local ok, err = pcall(vim.api.nvim_buf_set_name, buf, name)
  if not ok then
    pcall(vim.api.nvim_buf_set_name, buf, name .. " " .. vim.fn.strftime("%H%M%S"))
  end
end

local function to_ascii(s)
  s = s:gsub("á","a"):gsub("à","a"):gsub("ä","a"):gsub("â","a"):gsub("ã","a"):gsub("å","a")
       :gsub("Á","A"):gsub("À","A"):gsub("Ä","A"):gsub("Â","A"):gsub("Ã","A"):gsub("Å","A")
  s = s:gsub("é","e"):gsub("è","e"):gsub("ë","e"):gsub("ê","e"):gsub("É","E"):gsub("È","E"):gsub("Ë","E"):gsub("Ê","E")
  s = s:gsub("í","i"):gsub("ì","i"):gsub("ï","i"):gsub("î","i"):gsub("Í","I"):gsub("Ì","I"):gsub("Ï","I"):gsub("Î","I")
  s = s:gsub("ó","o"):gsub("ò","o"):gsub("ö","o"):gsub("ô","o"):gsub("õ","o"):gsub("Ó","O"):gsub("Ò","O"):gsub("Ö","O"):gsub("Ô","O"):gsub("Õ","O")
  s = s:gsub("ú","u"):gsub("ù","u"):gsub("ü","u"):gsub("û","u"):gsub("Ú","U"):gsub("Ù","U"):gsub("Ü","U"):gsub("Û","U")
  s = s:gsub("ñ","n"):gsub("Ñ","N"):gsub("ç","c"):gsub("Ç","C")
  return s
end

local function parse_html_table_to_markdown(tbl_html)
  local rows = {}
  for tr in tbl_html:gmatch("<tr[^>]*>(.-)</tr>") do
    local cells = {}
    for td in tr:gmatch("<t[hd][^>]*>(.-)</t[hd]>") do
      local c = td
      c = c:gsub("<strong[^>]*>(.-)</strong>", "**%1**")
      c = c:gsub("<b[^>]*>(.-)</b>", "**%1**")
      c = c:gsub("<em[^>]*>(.-)</em>", "_%1_")
      c = c:gsub("<i[^>]*>(.-)</i>", "_%1_")
      c = c:gsub("<code[^>]*>(.-)</code>", "`%1`")
      c = c:gsub("<br%s*/?>", " ")
      c = c:gsub("<[^>]+>", "")
      c = c:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
      c = c:gsub("\226\128\131", " ")
      c = c:gsub("\n", " "):gsub("|", "\\|")
      c = c:gsub("^%s+", ""):gsub("%s+$", "")
      table.insert(cells, c)
    end
    if #cells > 0 then
      table.insert(rows, cells)
    end
  end

  if #rows == 0 then return "" end

  local max_cols = 0
  for _, r in ipairs(rows) do
    if #r > max_cols then max_cols = #r end
  end
  if max_cols == 0 then return "" end

  for _, r in ipairs(rows) do
    while #r < max_cols do table.insert(r, "") end
  end

  local md_lines = {}
  local header = rows[1]
  table.insert(md_lines, "| " .. table.concat(header, " | ") .. " |")
  local seps = {}
  for _ = 1, max_cols do table.insert(seps, "---") end
  table.insert(md_lines, "| " .. table.concat(seps, " | ") .. " |")

  for i = 2, #rows do
    table.insert(md_lines, "| " .. table.concat(rows[i], " | ") .. " |")
  end

  return "\n" .. table.concat(md_lines, "\n") .. "\n"
end

-- helper: build lines for a single message, returns { lines, is_unread, id, reply_target }
local function build_message_lines(m, chat)
  if m == vim.NIL or m == nil then return nil end
  local lines = {}
  local from = "unknown"
  local fu = nv(m.from) and nv(m.from.user) and nv(m.from.user.displayName)
  if fu then from = fu end
  local body = ""
  local b = nv(m.body) and nv(m.body.content)
  if b then body = b end
  if body == vim.NIL then body = "" end
  -- detect <img> and replace with placeholders in-place to preserve position relative to text
  local img_srcs = {}
  body = body:gsub("<img[^>]+src=[\"']([^\"']+)[\"'][^>]*>", function(src)
    table.insert(img_srcs, src)
    return "\n\003IMG" .. #img_srcs .. "\003\n"
  end)

  -- 1. Extract and preserve tables: <table>...</table>
  local tables = {}
  body = body:gsub("<table[^>]*>(.-)</table>", function(tbl_content)
    local md_table = parse_html_table_to_markdown("<table>" .. tbl_content .. "</table>")
    table.insert(tables, md_table)
    return "\n\004TBL" .. #tables .. "\004\n"
  end)

  -- 2. Extract and preserve codeblocks: <codeblock class="Language"><code>...</code></codeblock>
  local codeblocks = {}
  body = body:gsub("<codeblock%s*class=[\"']([^\"']*)[\"'][^>]*>%s*<code>(.-)</code>%s*</codeblock>", function(lang, code)
    table.insert(codeblocks, { lang = lang or "", code = code })
    return "\001CB" .. #codeblocks .. "\001"
  end)
  body = body:gsub("<codeblock[^>]*>%s*<code>(.-)</code>%s*</codeblock>", function(code)
    table.insert(codeblocks, { lang = "", code = code })
    return "\001CB" .. #codeblocks .. "\001"
  end)

  -- 3. Extract and preserve inline code: <code>...</code>
  local inline_codes = {}
  body = body:gsub("<code>(.-)</code>", function(code)
    table.insert(inline_codes, code)
    return "\002IN" .. #inline_codes .. "\002"
  end)

  -- 4. Handle emojis & structure tags
  body = body:gsub('<emoji[^>]+alt="([^"]+)"[^>]*></emoji>', "%1")
  body = body:gsub("<emoji[^>]+alt='([^']+)'[^>]*></emoji>", "%1")
  body = body:gsub('<emoji[^>]+alt="([^"]+)"[^>]*/>', "%1")
  body = body:gsub("<br%s*/?>", "\n")
  body = body:gsub("</p>", "\n")
  body = body:gsub('<a[^>]*href="([^"]+)"[^>]*>(.-)</a>', function(url, txt)
    txt = txt:gsub("<[^>]+>", ""):gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("^%s+",""):gsub("%s+$","")
    if txt == "" then txt = url end
    return "[" .. txt .. "](" .. url .. ")"
  end)
  body = body:gsub("<a[^>]*href='([^']+)'[^>]*>(.-)</a>", function(url, txt)
    txt = txt:gsub("<[^>]+>", ""):gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("^%s+",""):gsub("%s+$","")
    if txt == "" then txt = url end
    return "[" .. txt .. "](" .. url .. ")"
  end)
  body = body:gsub("<[^>]+>", "")
  body = body:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
  body = body:gsub("\226\128\131", " ") -- U+2003 em space

  -- 5. Restore inline codes
  body = body:gsub("\002IN(%d+)\002", function(idx)
    local code = inline_codes[tonumber(idx)] or ""
    code = code:gsub("<[^>]+>", "")
    code = code:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    code = code:gsub("\226\128\131", " ")
    code = code:gsub("^%s+", ""):gsub("%s+$", "")
    return "`" .. code .. "`"
  end)

  -- 6. Restore codeblocks with markdown triple backticks
  body = body:gsub("\001CB(%d+)\001", function(idx)
    local item = codeblocks[tonumber(idx)]
    if not item then return "" end
    local code = item.code or ""
    local lang = (item.lang or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if lang == "plaintext" then
      lang = ""
    elseif lang == "shell" or lang == "sh" or lang == "zsh" then
      lang = "bash"
    elseif lang == "csharp" then
      lang = "cs"
    elseif lang == "javascript" then
      lang = "js"
    elseif lang == "typescript" then
      lang = "ts"
    elseif lang == "golang" then
      lang = "go"
    elseif lang == "" then
      -- Auto-detect language when Teams sends class=""
      local c_clean = code:gsub("<[^>]+>", ""):gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
      if c_clean:match("%f[%w]echo%f[%W]") or c_clean:match("%f[%w]ls%f[%W]") or c_clean:match("%f[%w]cd%f[%W]")
         or c_clean:match("%f[%w]git%f[%W]") or c_clean:match("%f[%w]curl%f[%W]") or c_clean:match("%f[%w]npm%f[%W]")
         or c_clean:match("%f[%w]export%f[%W]") or c_clean:match("%f[%w]sudo%f[%W]") then
        lang = "bash"
      elseif c_clean:match("^%s*[%{%[]") and (c_clean:match(":") or c_clean:match('"')) then
        lang = "json"
      elseif c_clean:match("^%s*<[%w_%-]+") or c_clean:match("</[%w_%-]+>%s*$") then
        lang = "html"
      elseif c_clean:match("%f[%w]local%f[%W]") or c_clean:match("%f[%w]require%f[%W]") or c_clean:match("%f[%w]function%f[%W]") then
        lang = "lua"
      elseif c_clean:match("%f[%w]def%f[%W]") or c_clean:match("%f[%w]import%f[%W]") then
        lang = "python"
      elseif c_clean:lower():match("%f[%w]select%f[%W]") or c_clean:lower():match("%f[%w]from%f[%W]") then
        lang = "sql"
      end
    end

    code = code:gsub("<br%s*/?>", "\n")
    code = code:gsub("<[^>]+>", "")
    code = code:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    code = code:gsub("\226\128\131", " ")
    code = code:gsub("^\n+", ""):gsub("\n+$", "")

    return "\n```" .. lang .. "\n" .. code .. "\n```\n"
  end)

  -- 7. Restore image tags in their exact position
  body = body:gsub("\003IMG(%d+)\003", function(idx)
    local i = tonumber(idx)
    local src = img_srcs[i] or ""
    local b64 = src:match("/hostedContents/([^/]+)/")
    local name = "image"
    if b64 then name = b64:sub(1, 20) end
    if src:lower():find("%.gif") then name = "gif" end
    return string.format("[Image: %s - press gx to open]", name)
  end)

  -- 8. Restore Markdown tables
  body = body:gsub("\004TBL(%d+)\004", function(idx)
    return tables[tonumber(idx)] or ""
  end)

  body = body:gsub("^%s+", ""):gsub("%s+$", "")
  local dt = format_date(nv(m.createdDateTime) or "")
  local is_unread = is_message_unread(m, chat)
  local header = string.format("**%s** (%s):", from, dt)
  if is_unread then header = "● " .. header end
  table.insert(lines, header)
  local mid = nv(m.id)
  -- capture reply info
  local reply_preview = nil
  local reply_target = nil
  local atts = nv(m.attachments)
  if atts and type(atts) == "table" and #atts > 0 then
    for _, a in ipairs(atts) do
      if a ~= vim.NIL and nv(a.contentType) == "messageReference" then
        local content = nv(a.content) or ""
        reply_preview = content:match('"messagePreview":"([^"]+)"') or "message"
        reply_target = content:match('"messageId":"([^"]+)"')
        break
      end
    end
  end
  local deleted = nv(m.deletedDateTime)
  local hosted = nv(m.hostedContents)
  local mtype = nv(m.messageType)
  local edetail = nv(m.eventDetail)
  local rendered_file = false
  local function render_attachments()
    if atts and type(atts) == "table" and #atts > 0 then
      for _, a in ipairs(atts) do
        if a == vim.NIL then goto ac end
        local ct = nv(a.contentType) or "attachment"
        if ct == "reference" then
          local hid = hosted and hosted[1] and (nv(hosted[1].id) or nv(hosted[1].contentId)) or "0"
          local contentUrl = nv(a.contentUrl) or ""
          local src = contentUrl ~= "" and contentUrl or (is_channel and string.format("https://graph.microsoft.com/v1.0/teams/%s/channels/%s/messages/%s/hostedContents/%s/$value", team_id or "", chat_id, mid or "", hid) or string.format("https://graph.microsoft.com/v1.0/chats/%s/messages/%s/hostedContents/%s/$value", chat_id, mid or "", hid))
          table.insert(img_srcs, src)
          local fname = nv(a.name) or ""
          if fname == "" and contentUrl ~= "" then fname = contentUrl:match("/([^/%?]+)%??") or "" end
          fname = fully_decode(fname):gsub("%%20"," "):gsub("%%2E","."):gsub("%%5F","_")
          if fname == "" then fname = hid ~= "0" and hid:sub(1,20) or "file" end
          local host = contentUrl:match("https://([^/]+)/") or src:match("https://([^/]+)/") or "graph.microsoft.com"
          table.insert(lines, string.format("  [File: %s (%s) - press gx to open]", fname, host))
          rendered_file = true
        elseif ct == "tabReference" and (nv(a.contentUrl) or "") == "" then
          local tname = fully_decode(nv(a.name) or "")
          local tid, ttn = parse_tab_reference(nv(a.content) or "")
          if tname == "" then tname = (ttn and fully_decode(ttn)) or "tab" end
          if tid or tname ~= "tab" then
            table.insert(lines, string.format("  [Tab: %s - resolving file...]", tname))
          else
            table.insert(lines, string.format("  [Tab: %s]", tname))
          end
        elseif ct ~= "messageReference" and nv(a.contentUrl) ~= "" and nv(a.contentUrl) ~= nil then
          local contentUrl = nv(a.contentUrl) or ""
          local src = contentUrl
          local fname = nv(a.name) or ""
          if fname == "" and contentUrl ~= "" then fname = contentUrl:match("/([^/%?]+)%??") or "" end
          fname = fully_decode(fname):gsub("%%20"," "):gsub("%%2E","."):gsub("%%5F","_")
          local host = contentUrl:match("https://([^/]+)/") or "graph.microsoft.com"
          table.insert(img_srcs, src)
          table.insert(lines, string.format("  [File: %s (%s) - press gx to open]", fname, host))
          rendered_file = true
        elseif ct == "messageReference" then goto ac
        else table.insert(lines, "  " .. string.format("[Attachment: %s]", ct)) end
        ::ac::
      end
    end
    if hosted and type(hosted) == "table" and #hosted > 0 and not rendered_file then
      local hid = nv(hosted[1].id) or nv(hosted[1].contentId) or "0"
      local src = is_channel and string.format("https://graph.microsoft.com/v1.0/teams/%s/channels/%s/messages/%s/hostedContents/%s/$value", team_id or "", chat_id, mid or "", hid) or string.format("https://graph.microsoft.com/v1.0/chats/%s/messages/%s/hostedContents/%s/$value", chat_id, mid or "", hid)
      table.insert(img_srcs, src)
      local host = src:match("https://([^/]+)/") or "graph.microsoft.com"
      table.insert(lines, string.format("  [File: %s (%s) - press gx to open]", hid:sub(1,20), host))
    end
  end
  if body ~= "" or #img_srcs > 0 then
    if reply_preview then
      table.insert(lines, "  " .. string.format("_↳ reply to: %s_", reply_preview))
    end
    if body ~= "" then
      for line in body:gmatch("[^\n]+") do
        table.insert(lines, "  " .. line)
      end
    end
    render_attachments()
  else
    if deleted then
      table.insert(lines, "  " .. string.format("_Message deleted on %s_", format_date(deleted)))
    elseif atts and type(atts) == "table" and #atts > 0 then
      render_attachments()
    elseif hosted and type(hosted) == "table" and #hosted > 0 then
      render_attachments()
    elseif mtype and mtype ~= "message" then
      local otype = edetail and nv(edetail["@odata.type"]) or ""
      if otype:find("callStarted") then
        local init = edetail and nv(edetail.initiator) and nv(edetail.initiator.displayName) or "unknown"
        table.insert(lines, "  " .. string.format("[System: Call started by %s]", init))
      elseif otype:find("callEnded") then
        local dur = edetail and (nv(edetail.callDuration) or nv(edetail.duration)) or ""
        if dur ~= "" then
          table.insert(lines, "  " .. string.format("[System: Call ended - duration %s]", dur))
        else
          table.insert(lines, "  [System: Call ended]")
        end
      elseif otype:find("membersAdded") then
        local initiator = edetail and nv(edetail.initiator) and nv(nv(edetail.initiator).user) and nv(nv(nv(edetail.initiator).user).displayName) or "unknown"
        if initiator == "unknown" or initiator == "" then
          local iid = edetail and nv(edetail.initiator) and nv(nv(edetail.initiator).user) and nv(nv(nv(edetail.initiator).user).id)
          if iid then
            -- try resolve via chat members
            for _, cm in ipairs(nv(chat.members) or {}) do
              if nv(cm.userId) == iid or nv(cm.id) == iid then
                initiator = nv(cm.displayName) or initiator
                break
              end
            end
          end
        end
        local members = nv(edetail.members)
        local names = {}
        if members and type(members) == "table" then
          for _, m in ipairs(members) do
            if m ~= vim.NIL then
              local n = nv(m.displayName)
              if not n or n == "" then
                local mid = nv(m.id)
                -- try chat members
                for _, cm in ipairs(nv(chat.members) or {}) do
                  if nv(cm.userId) == mid or nv(cm.id) == mid then
                    n = nv(cm.displayName) or mid
                    break
                  end
                end
                n = n or mid or "unknown"
              end
              table.insert(names, n)
            end
          end
        end
        local nameStr = table.concat(names, ", ")
        local hist = nv(edetail.visibleHistoryStartDateTime) and nv(edetail.visibleHistoryStartDateTime) ~= "0001-01-01T00:00:00Z" and " and shared all chat history" or ""
        table.insert(lines, string.format("  [System: %s added %s to the chat%s]", initiator, nameStr, hist))
      elseif otype:find("membersDeleted") then
        local members = nv(edetail.members)
        local names = {}
        if members and type(members) == "table" then
          for _, m in ipairs(members) do
            if m ~= vim.NIL then
              local n = nv(m.displayName)
              if not n or n == "" then
                local mid = nv(m.id)
                for _, cm in ipairs(nv(chat.members) or {}) do
                  if nv(cm.userId) == mid or nv(cm.id) == mid then
                    n = nv(cm.displayName) or mid
                    break
                  end
                end
                -- fallback to Graph lookup will be async, for now use id
                n = n or mid or "unknown"
              end
              table.insert(names, n)
            end
          end
        end
        local nameStr = table.concat(names, ", ")
        -- check initiator vs nameStr to decide left vs removed
        local initiator = edetail and nv(edetail.initiator) and nv(nv(edetail.initiator).user) and nv(nv(nv(edetail.initiator).user).displayName)
        if not initiator or initiator == "" then
          local iid = edetail and nv(edetail.initiator) and nv(nv(edetail.initiator).user) and nv(nv(nv(edetail.initiator).user).id)
          if iid then
            for _, cm in ipairs(nv(chat.members) or {}) do
              if nv(cm.userId) == iid or nv(cm.id) == iid then
                initiator = nv(cm.displayName) or initiator
                break
              end
            end
          end
          if not initiator or initiator == "" then initiator = nameStr end
        end
        if #names == 1 and nameStr == initiator then
          table.insert(lines, string.format("  [System: %s left the chat]", nameStr))
        else
          initiator = initiator or "unknown"
          table.insert(lines, string.format("  [System: %s removed %s from the chat]", initiator, nameStr))
        end
      elseif edetail and type(edetail) == "table" then
        table.insert(lines, "  " .. string.format("[System event: %s]", vim.inspect(edetail):gsub("\n"," "):sub(1,80)))
      else
        table.insert(lines, "  " .. string.format("[System message: %s]", mtype))
      end
    else
      table.insert(lines, "  _no body_ (empty)")
    end
    -- images handled as placeholder, gx will download on demand
  end
  table.insert(lines, "")
  return {
    lines = lines,
    is_unread = is_unread,
    id = mid,
    reply_preview = reply_preview,
    reply_target = reply_target,
    img_srcs = img_srcs,
  }
end

-- foldexpr for the chats list buffer: markdown-style headers fold
-- (# level 1, ## level 2), everything else inherits. Used as
-- v:lua.require'ms-teams.ui'.list_fold_expr(v:lnum)
function M.list_fold_expr(lnum)
  local ok, line = pcall(vim.fn.getline, lnum)
  if not ok or not line then return "=" end
  local hashes = line:match("^(#+)%s")
  if hashes then
    return ">" .. math.min(#hashes, 7)
  end
  return "="
end

function M.pick_chats()
  local cache = require("ms-teams.cache")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  set_listed_scratch(buf, "ms-teams://list-chats")
  vim.bo[buf].modifiable = false
  -- all writes go through here: with nomodifiable, stray keystrokes can no
  -- longer shift lines and desync line_to_chat/line_to_entry maps
  local function set_list_lines(new_lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    vim.bo[buf].modifiable = false
  end
  local cached = cache.load("chats", 300)
  local current_filter = nil -- shown in header
  local show_all_limit = false -- toggled by gS
  local show_unread_only = false -- toggled by U
  if vim.g.ms_teams_show_meeting == nil then vim.g.ms_teams_show_meeting = true end
  local enriching = false
  local enriched = {}
  local teams_data = nil
  local channels_map = {}
  -- per-channel unread state from latest-message enrichment (list_channels
  -- has no preview data): cid -> {dt, ref, from_self, known_other}
  local channel_state = {}
  local function clean(s) local t = (nv(s) or ""):gsub("\n"," "):gsub("\r"," "); return t end
  local function load_all_channels(teams, cb)
    local pending = #teams
    if pending == 0 then if cb then cb() end; return end
    for _, team in ipairs(teams) do
      require("ms-teams.graph").list_channels(team.id, function(channels, err)
        channels_map[team.id] = channels or {}
        pending = pending - 1
        if pending == 0 and cb then cb() end
      end)
    end
  end
  local render_and_bind
  -- coalesce rapid background re-renders into one trailing paint: on open,
  -- cache/teams/network/channels/enrichment fire within seconds and each
  -- full set_lines + cursor reset + ts restart flickers. Explicit renders
  -- (open, R, search, :e) stay immediate and cancel any pending paint.
  local render_seq = 0
  -- boot hold: on open, background completions (teams, channels, list refresh,
  -- both enrichment batches) arrive bursting over seconds; painting each one
  -- flickers. Hold them and paint once when the burst settles (or the hold
  -- expires, so throttled stragglers can't block the paint forever).
  local uv_now = (vim.uv or vim.loop).now
  local boot_hold_until = uv_now() + 3000
  local boot_pending_args = nil
  local function request_render(chats, all_chats, is_cached, filter_term, opts)
    opts = opts or {}
    if not opts.background then
      render_seq = render_seq + 1 -- invalidate pending background paint
      boot_pending_args = nil
      render_and_bind(chats, all_chats, is_cached, filter_term)
      return
    end
    if uv_now() < boot_hold_until then
      -- still in open burst: remember latest, single paint at hold expiry
      boot_pending_args = { chats, all_chats, is_cached, filter_term }
      return
    end
    render_seq = render_seq + 1
    local my_seq = render_seq
    local args = { chats, all_chats, is_cached, filter_term }
    vim.defer_fn(function()
      if my_seq ~= render_seq then return end -- superseded
      if not vim.api.nvim_buf_is_valid(buf) then return end
      render_and_bind(args[1], args[2], args[3], args[4])
    end, 150)
  end
  vim.defer_fn(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local args = boot_pending_args
    boot_pending_args = nil
    if args then
      request_render(args[1], args[2], args[3], args[4]) -- immediate + invalidates
    end
  end, 3000)
  do
    local tc = cache.load("teams", 300)
    if tc and tc.teams then teams_data = tc.teams; channels_map = cache.load("teams_channels") or {} end
  end
  -- render inmediato con cache (sin red), highlight async después
  if teams_data and next(channels_map) ~= nil then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        local ok, all = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_all_chats")
        if ok and all then request_render(all, all, false, current_filter or "", { background = true }) end
      end
    end)
  end
  vim.defer_fn(function()
    if not teams_data then
      require("ms-teams.graph").list_teams(function(nt, err)
        if nt and #nt>0 then
          teams_data = nt
          cache.save("teams", {teams=nt})
          load_all_channels(nt, function()
            cache.save("teams_channels", channels_map)
            vim.schedule(function()
              if vim.api.nvim_buf_is_valid(buf) then
                local ok, all = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_all_chats")
                if ok and all then request_render(all, all, false, current_filter or "", { background = true }) end
              end
            end)
          end)
        end
      end)
    else
      -- cache hit: no bloquear render, refresco en background solo para highlight
      vim.defer_fn(function()
        -- solo refresca channels si hace falta (R fuerza, aquí es best-effort)
        load_all_channels(teams_data, function()
          cache.save("teams_channels", channels_map)
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(buf) then
              local ok, all = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_all_chats")
              if ok and all then request_render(all, all, false, current_filter or "", { background = true }) end
            end
          end)
        end)
      end, 5000)
    end
  end, 0)
  render_and_bind = function(chats, all_chats, is_cached, filter_term)
    render_seq = render_seq + 1 -- any direct paint invalidates pending background paints
    if filter_term ~= nil then current_filter = filter_term end
    if not chats or #chats == 0 then
      -- keep header with filter info even when empty
      local empty_header = "# Teams chats (0/" .. #(all_chats or chats) .. " shown"
        .. (current_filter and current_filter ~= "" and ' | filter: "' .. current_filter .. '"' or "")
        .. (is_cached and " - cached" or "") .. ")"
      set_list_lines({ empty_header, "", "_no matches_ — / para buscar, R refresh, q close", "" })
      -- still bind vars so / can be retried
      pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_all_chats", all_chats or chats)
      vim.notify("no chats found" .. (current_filter and ' for "' .. current_filter .. '"' or ""), vim.log.levels.WARN)
      return
    end
    local hidden_path = require("ms-teams.config").options.data_dir .. "/hidden.json"
    local function load_hidden()
      if vim.fn.filereadable(hidden_path) ~= 1 then return {} end
      local ok, j = pcall(vim.json.decode, table.concat(vim.fn.readfile(hidden_path), "\n"))
      if ok and j then return j end
      return {}
    end
    local function save_hidden(ids)
      vim.fn.mkdir(vim.fn.fnamemodify(hidden_path, ":h"), "p")
      vim.fn.writefile({ vim.json.encode(ids) }, hidden_path)
      pcall(vim.fn.system, { "chmod", "600", hidden_path })
    end
    local hidden = load_hidden()
    local hidden_set = {}
    for _, id in ipairs(hidden) do hidden_set[id] = true end
    local filtered = {}
    for _, c in ipairs(chats) do
      if c ~= vim.NIL and nv(c.id) and not hidden_set[nv(c.id)] then table.insert(filtered, c) end
    end
    chats = filtered
    table.sort(chats, function(a, b)
      -- pin 48:notes siempre arriba como en Teams
      if nv(a.id)=="48:notes" then return true end
      if nv(b.id)=="48:notes" then return false end
      local ap = nv(a.lastMessagePreview) and nv(nv(a.lastMessagePreview).createdDateTime)
      local bp = nv(b.lastMessagePreview) and nv(nv(b.lastMessagePreview).createdDateTime)
      local al = ap or nv(a.lastUpdatedDateTime) or ""
      local bl = bp or nv(b.lastUpdatedDateTime) or ""
      return al > bl
    end)
    -- si 48:notes no estaba, ya lo inyectó graph.lua:70, pero asegura que no quede fuera del top 30
    do
      local idx=nil; for i,c in ipairs(chats) do if nv(c.id)=="48:notes" then idx=i; break end end
      if idx and idx>1 then local n=table.remove(chats, idx); table.insert(chats,1,n) end
    end
    local all_for_search = all_chats or vim.deepcopy(chats)
    local display = {}
    -- during an active filter (current_filter ~= nil/"") do NOT hide meetings — lets you find self/meeting chats
    local is_filtering = current_filter and current_filter ~= ""
    for _, c in ipairs(chats) do
      local pass_meeting = is_filtering or nv(c.chatType) ~= "meeting" or vim.g.ms_teams_show_meeting
      local pass_unread = not show_unread_only or has_unread(c)
      if pass_meeting and pass_unread then table.insert(display, c) end
    end
    -- when filtering, prioritize self-chat (1 member) > oneOnOne > rest, then by recency
    if is_filtering then
      local function is_self(chat)
        local members = nv(chat.members)
        if not members or type(members)~="table" then return false end
        local valid = 0
        for _,m in ipairs(members) do if m~=vim.NIL and nv(m.displayName) then valid=valid+1 end end
        return valid==1 and nv(chat.chatType)=="oneOnOne"
      end
      table.sort(display, function(a, b)
        local a_self = is_self(a) and 2 or 0
        local b_self = is_self(b) and 2 or 0
        if a_self ~= b_self then return a_self > b_self end
        local a_one = nv(a.chatType) == "oneOnOne" and 1 or 0
        local b_one = nv(b.chatType) == "oneOnOne" and 1 or 0
        if a_one ~= b_one then return a_one > b_one end
        local ap = nv(a.lastMessagePreview) and nv(nv(a.lastMessagePreview).createdDateTime)
        local bp = nv(b.lastMessagePreview) and nv(nv(b.lastMessagePreview).createdDateTime)
        local al = ap or nv(a.lastUpdatedDateTime) or ""
        local bl = bp or nv(b.lastUpdatedDateTime) or ""
        return al > bl
      end)
    end
    if not is_filtering and not show_all_limit and #display > 30 then
      local t = {}
      for i=1,30 do t[i]=display[i] end
      display = t
    end
    local unread_by_id = {}
    for _, c in ipairs(all_for_search) do if has_unread(c) then unread_by_id[nv(c.id)] = true end end
    -- channel unread: list_channels objects carry no preview/viewpoint, so
    -- consult enrichment state (latest message vs local read reference)
    local function channel_is_unread(cid)
      if not cid then return false end
      if unread_by_id[cid] then return true end
      local st = channel_state[cid]
      if not st then return false end
      -- live mr/mu override always wins over stored state
      local ok_lr, live = pcall(require("ms-teams.cache").get_last_read, cid)
      if ok_lr and live and live ~= "" then
        return st.dt > live and not st.from_self
      end
      if st.ref then return st.dt > st.ref and not st.from_self end
      return st.known_other == true
    end
    local header = "# Teams chats (" .. #display .. "/" .. #all_for_search .. " shown"
      .. (current_filter and current_filter ~= "" and ' | filter: "' .. current_filter .. '"' or "")
      .. (show_unread_only and " - unread only" or "")
      .. (is_cached and " - cached" or "") .. (is_filtering and " - meeting included" or (vim.g.ms_teams_show_meeting and "" or " - meeting hidden, M to show")) .. ")"
    local lines = {}
    table.insert(lines, header)
    local line_to_chat = {}
    local line_to_entry = {}
    local unread_lines = {}
      for _, chat in ipairs(display) do
        local base = format_chat(chat)
        local type_icon = get_chat_type_icon(chat)
        local line = type_icon ~= "" and (type_icon .. "  " .. base) or base
        if nv(chat.chatType) == "meeting" then line = line .. " (meeting)" end
        table.insert(lines, line)
      local lnum = #lines
      line_to_chat[lnum] = chat
      line_to_entry[lnum] = {type="chat", chat=chat}
      if has_unread(chat) then unread_lines[lnum] = true end
    end
    -- Teams section at bottom
    local sorted_teams = nil
    -- per-channel unread snapshot for live mr/mu updates (see update fn)
    local channel_unread = {}
    if teams_data and #teams_data > 0 then
      table.insert(lines, "")
      table.insert(lines, "# Teams (" .. #teams_data .. ")")
      local teams_header_lnum = #lines - 1
      sorted_teams = vim.deepcopy(teams_data)
      table.sort(sorted_teams, function(a,b) return (a.displayName or ""):lower() < (b.displayName or ""):lower() end)
      for _, team in ipairs(sorted_teams) do
        local channels = channels_map[team.id] or {}
        -- build map from channel id -> chat entry for has_unread check
        local chat_by_chid = {}
        for _, c in ipairs(all_for_search) do
          if nv(c.chatType) == "channel" and nv(c.teamId) == nv(team.id) then
            chat_by_chid[nv(c.id)] = c
          end
        end
        local team_has_unread = false
        -- first check via chats
        for cid, ch_chat in pairs(chat_by_chid) do
          if unread_by_id[cid] then team_has_unread = true; break end
        end
        -- also check channels_map entries via enrichment state (channel
        -- objects from list_channels carry no preview/viewpoint data)
        if not team_has_unread then
          for _, ch in ipairs(channels) do
            if ch ~= vim.NIL and channel_is_unread(nv(ch.id)) then team_has_unread = true; break end
          end
        end
        table.insert(lines, "## " .. clean(team.displayName) .. " (" .. #channels .. ")")
        local t_lnum = #lines
        line_to_entry[t_lnum] = {type="team", team=team}
        if team_has_unread then unread_lines[t_lnum] = true end
        -- render individual channels under team (no indent, channel icon
        -- prefix like chats) with per-channel highlight
        table.sort(channels, function(a,b) return (nv(a.displayName) or ""):lower() < (nv(b.displayName) or ""):lower() end)
        local channel_icon = get_chat_type_icon({ chatType = "channel" })
        for _, ch in ipairs(channels) do
          if ch ~= vim.NIL then
            local cid = nv(ch.id)
            local cc = chat_by_chid[cid]
            local is_unread = false
            if cc then is_unread = has_unread(cc) end
            if not is_unread then is_unread = channel_is_unread(cid) end
            local ch_name = clean(nv(ch.displayName) or cid or "channel")
            local ch_line = channel_icon ~= "" and (channel_icon .. "  " .. ch_name) or ch_name
            table.insert(lines, ch_line)
            local c_lnum = #lines
            line_to_entry[c_lnum] = {type="channel", channel=ch, team=team}
            if cid then channel_unread[cid] = is_unread end
            if is_unread then unread_lines[c_lnum] = true end
          end
        end
      end
    end
    pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_channel_unread", channel_unread)
    -- enrich team channels missing from list_chats (e.g. Random): fetch the
    -- latest message per channel; get_chat does NOT work for channel ids
    -- and list_channels carries no preview data. Retries are time-gated
    -- (failures retry after 5 min, states revalidate after 15 min) so a
    -- throttled round never latches the buffer into a stale state.
    do
      local now = os.time()
      local ok_att, attempted = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_teams_attempted")
      if not (ok_att and type(attempted) == "table") then attempted = {} end
      local chat_by_chid_all = {}
      for _, c in ipairs(all_for_search) do
        if nv(c.chatType) == "channel" then
          local cid = nv(c.id)
          if cid then chat_by_chid_all[cid] = c end
        end
      end
      local missing = {}
      for _, team in ipairs(sorted_teams or {}) do
        local team_channels = channels_map[team.id] or {}
        for _, ch in ipairs(team_channels) do
          if ch ~= vim.NIL then
            local cid = nv(ch.id)
            if cid and not chat_by_chid_all[cid] then
              local st = channel_state[cid]
              local fresh = st and st.at and (now - st.at) < 900
              local last_att = attempted[cid] or 0
                if not fresh and (now - last_att) >= 300 then
                  table.insert(missing, { cid = cid, team_id = team.id })
                end
            end
          end
        end
      end
      pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_teams_attempted", attempted)
        if #missing > 0 then
          local to_fetch = {}
          for i = 1, math.min(8, #missing) do table.insert(to_fetch, missing[i]) end
          local pending = #to_fetch
          local changed = false
          local failed = 0
          local first_err = nil
          local function finish_one()
            pending = pending - 1
            if pending == 0 then
              if failed > 0 then
                vim.notify(string.format("ms-teams: channel unread check failed for %d/%d channels (%s)", failed, #to_fetch, tostring(first_err or "?"):sub(1, 120)), vim.log.levels.WARN)
              end
              if changed then
                vim.schedule(function()
                  if vim.api.nvim_buf_is_valid(buf) then
                    local okAll, _ = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_all_chats")
                    if okAll then
                      request_render(all_for_search, all_for_search, false, current_filter or "", { background = true })
                    end
                  end
                end)
              end
            end
          end
          for _, item in ipairs(to_fetch) do
            require("ms-teams.graph").list_channel_messages(item.team_id, item.cid, function(msgs, err, _)
              if err or not msgs then
                failed = failed + 1
                if not first_err then first_err = err end
              end
              if not err and msgs and #msgs > 0 then
                local latest, latest_dt = nil, ""
                for _, m in ipairs(msgs) do
                  if m ~= vim.NIL then
                    local dt = nv(m.createdDateTime) or ""
                    if dt > latest_dt then latest_dt = dt; latest = m end
                  end
                end
                if latest and latest_dt ~= "" then
                  local cache = require("ms-teams.cache")
                  local ref = cache.get_last_read(item.cid)
                  if not ref then
                    ref = channel_seen_newest(item.cid)
                  end
                  local f0 = latest.from and nv(latest.from)
                  local pfrom = f0 and nv(f0.user)
                  local from_self = (pfrom and is_from_me(pfrom)) and true or false
                  local known_other = (pfrom and not from_self) and true or false
                  -- without local reference, only recent messages count: a
                  -- years-old latest message was surely seen already
                  if not ref and known_other then
                    local max_age = 30
                    local ok_cfg, cfg = pcall(require, "ms-teams.config")
                    if ok_cfg and cfg.options and cfg.options.channels and cfg.options.channels.unread_max_age_days then
                      max_age = cfg.options.channels.unread_max_age_days
                    end
                    local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - max_age * 86400)
                    if latest_dt < cutoff then known_other = false end
                  end
                  if ref or known_other then
                    channel_state[item.cid] = { dt = latest_dt, ref = ref, from_self = from_self, known_other = known_other, at = os.time() }
                    changed = true
                  end
                end
              end
              finish_one()
            end)
          end
        end
      end
    -- dirty check to avoid flicker when content unchanged
    local do_render_list = true
    if vim.api.nvim_buf_is_valid(buf) then
      local ok_old, old = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
      if ok_old and old and #old == #lines then
        local same = true
        for i = 1, #lines do if old[i] ~= lines[i] then same = false; break end end
        if same then do_render_list = false end
      end
    end
    if do_render_list then
      -- preserve view
      local win_list = vim.fn.bufwinid(buf)
      local saved = nil
      if win_list ~= -1 then saved = vim.api.nvim_win_call(win_list, function() return vim.fn.winsaveview() end) end
      set_list_lines(lines)
      if saved and win_list ~= -1 then pcall(vim.api.nvim_win_call, win_list, function() vim.fn.winrestview(saved) end) end
    end
    -- highlights re-applied only when the unread set actually changed;
    -- blind clear+re-add on every background render is itself flicker
    local sig_list = {}
    for lnum,_ in pairs(unread_lines) do table.insert(sig_list, lnum) end
    table.sort(sig_list)
    local hl_group_now = get_unread_hl_group()
    local sig = hl_group_now .. "|" .. table.concat(sig_list, ",")
    local ok_sig, prev_sig = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_unread_sig")
    -- TEMPDBG: trace Ryan highlight decisions
    do
      local rid = "19:99a2c29a-e9aa-40ee-a722-36bed8376a05_9ac8b6e1-343d-4533-b010-9e9182cd53ff@unq.gbl.spaces"
      local in_set, ryan_lnum = false, nil
      for _, l in ipairs(sig_list) do
        local c = line_to_chat[l]
        if c and nv(c.id) == rid then in_set = true; ryan_lnum = l; break end
      end
      local ns0 = vim.api.nvim_create_namespace("ms_teams_unread")
      local marks = #vim.api.nvim_buf_get_extmarks(buf, ns0, { 0, 0 }, { -1, -1 }, {})
      pcall(vim.fn.writefile, { string.format("%s render unread=%s ryan_lnum=%s sig_same=%s marks=%d nlines=%d", os.date("%H:%M:%S"), tostring(in_set), tostring(ryan_lnum), tostring(ok_sig and prev_sig == sig), marks, #lines) }, "/tmp/ms_unread.log", "a")
    end
    if do_render_list or not (ok_sig and prev_sig == sig) then
      local ns = vim.api.nvim_create_namespace("ms_teams_unread")
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      for _, lnum in ipairs(sig_list) do vim.api.nvim_buf_add_highlight(buf, ns, hl_group_now, lnum-1,0,eol_col(buf,lnum)) end
      pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_ns", ns)
      pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_unread_sig", sig)
      -- TEMPDBG post-apply state
      local ns0b = vim.api.nvim_create_namespace("ms_teams_unread")
      local marks_after = #vim.api.nvim_buf_get_extmarks(buf, ns0b, { 0, 0 }, { -1, -1 }, {})
      pcall(vim.fn.writefile, { string.format("%s applied sig=%s marks_after=%d", os.date("%H:%M:%S"), sig, marks_after) }, "/tmp/ms_unread.log", "a")
    end
    vim.api.nvim_buf_set_var(buf, "ms_teams_chats", display)
    vim.api.nvim_buf_set_var(buf, "ms_teams_line_to_chat", line_to_chat)
    vim.api.nvim_buf_set_var(buf, "ms_teams_line_to_entry", line_to_entry)
    vim.api.nvim_buf_set_var(buf, "ms_teams_all_chats", all_for_search)
    vim.api.nvim_buf_set_var(buf, "ms_teams_teams", teams_data)
    -- never yank cursor on background renders: only clamp if it ended out
    -- of range (e.g. list shrank); the user's position is otherwise kept
    local win_list2 = vim.fn.bufwinid(buf)
    if win_list2 ~= -1 then
      local ok_cur, cur = pcall(vim.api.nvim_win_get_cursor, win_list2)
      if ok_cur and cur then
        local lc = vim.api.nvim_buf_line_count(buf)
        if cur[1] > lc then pcall(vim.api.nvim_win_set_cursor, win_list2, {lc, 0}) end
      end
    end
    -- restart treesitter only if not active (:e detaches it); restarting on
    -- every background render re-highlights the whole buffer = flicker
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "markdown" then
        local ok_hl, active = pcall(function() return vim.treesitter.highlighter.active[buf] end)
        if not (ok_hl and active) then
          pcall(vim.treesitter.start, buf)
        end
      end
    end, 50)
    -- enrich oneOnOne chats that still show as oneOnOne due to $expand=lastMessagePreview only (no members)
    do
      local to_fetch = {}
      for _, c in ipairs(all_for_search) do
        if nv(c.chatType) == "oneOnOne" then
          local fmt = format_chat(c)
          if fmt:match("^oneOnOne") and not enriched[nv(c.id)] then table.insert(to_fetch, c) end
        end
      end
      if #to_fetch > 0 and not enriching then
        enriching = true
        local pending = #to_fetch
        for _, c in ipairs(to_fetch) do
          enriched[nv(c.id)] = true
          require("ms-teams.graph").get_chat(nv(c.id), function(full, err)
            if full and nv(full.members) and type(nv(full.members)) == "table" then c.members = nv(full.members)
            elseif full and full.members then c.members = full.members end
            pending = pending - 1
            if pending == 0 then
              enriching = false
              vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) then
                  local okAll, _ = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_all_chats")
                  if okAll then
                    pcall(require("ms-teams.cache").save, "chats", {chats=all_for_search})
                    request_render(all_for_search, all_for_search, false, current_filter or "", { background = true })
                  end
                end
              end)
            end
          end)
        end
      end
    end
    local function open_for(lnum, open)
      local entry = line_to_entry[lnum]
      if entry then
        if entry.type == "channel" then
          local ch = entry.channel
          local team = entry.team
          local topic = nv(ch.displayName) or ch.id
          local chat = {id=ch.id, chatType="channel", topic=topic, teamId=nv(team.id), members={}, displayName=topic}
          M.show_messages(chat, open)
          return
        elseif entry.type == "team" then
          if open == "split" then vim.cmd("split")
          elseif open == "vsplit" then vim.cmd("vsplit") end
          M.pick_teams()
          return
        elseif entry.type == "chat" then
          local chat = entry.chat
          if chat and nv(chat.id) then M.show_messages(chat, open); return end
        end
      end
      local chat = line_to_chat[lnum]
      if not chat or nv(chat.id)==nil then vim.notify("no chat on this line",vim.log.levels.WARN); return end
      M.show_messages(chat, open)
    end
    vim.keymap.set("n", "<CR>", function() open_for(vim.api.nvim_win_get_cursor(0)[1],"current") end, {buffer=buf})
    vim.keymap.set("n", "<C-s>", function() open_for(vim.api.nvim_win_get_cursor(0)[1],"split") end, {buffer=buf})
    vim.keymap.set("n", "<C-v>", function() open_for(vim.api.nvim_win_get_cursor(0)[1],"vsplit") end, {buffer=buf})
    vim.keymap.set("n", "g/", function()
      vim.ui.input({prompt="Search chats (name): "}, function(q)
        if not q then return end
        local q_raw = q
        q=q:lower()
        if q=="" then
          render_and_bind(all_for_search, all_for_search, false, "")
          vim.notify("search cleared",vim.log.levels.INFO)
          return
        end
        local function do_filter(chats_to_filter)
          local filt={}
          for _,c in ipairs(chats_to_filter) do
            local name=format_chat(c):lower()
            local members=nv(c.members)
            local mstr=""
            local tstr=(nv(c.topic) or ""):lower()
            if members and type(members)=="table" then
              for _,m in ipairs(members) do
                if m~=vim.NIL then
                  if nv(m.displayName) then mstr=mstr.." "..nv(m.displayName):lower() end
                  if nv(m.email) then mstr=mstr.." "..nv(m.email):lower() end
                end
              end
            end
            if name:find(q,1,true) or mstr:find(q,1,true) or tstr:find(q,1,true) then table.insert(filt,c) end
          end
          render_and_bind(filt, chats_to_filter, false, q_raw)
          vim.notify(string.format("found %d/%d for \"%s\" (meetings incluidos, oneOnOne primero)",#filt,#chats_to_filter,q_raw),vim.log.levels.INFO)
        end
        if #all_for_search < 100 then
          vim.notify("searching over more chats (async, up to 500)...",vim.log.levels.INFO)
          require("ms-teams.graph").list_chats(function(more,err)
            if err then do_filter(all_for_search); return end
            vim.schedule(function() do_filter(more) end)
          end,{all=true,top=50,limit=500})
        else
          do_filter(all_for_search)
        end
      end)
    end, {buffer=buf})
    vim.keymap.set("n", "g?", function()
      local hb = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_option(hb, "filetype", "markdown")
      vim.api.nvim_buf_set_option(hb, "buftype", "nofile")
      vim.api.nvim_buf_set_lines(hb, 0, -1, false, {
        "# Teams Help",
        "",
        "<CR> open in place",
        "<C-s> open in horizontal split",
        "<C-v> open in vertical split",
        "g/ search",
        "U unread",
        "M meeting",
        "gS show more/less",
        "R refresh",
        "<C-x> hide",
        "q close",
      })
      local width = 30
      local height = 13
      local row = math.floor((vim.o.lines - height) / 2)
      local col = math.floor((vim.o.columns - width) / 2)
      local win = vim.api.nvim_open_win(hb, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
      })
      vim.api.nvim_buf_set_keymap(hb, "n", "q", "<cmd>close<cr>", {silent=true})
      vim.api.nvim_buf_set_keymap(hb, "n", "<Esc>", "<cmd>close<cr>", {silent=true})
      vim.api.nvim_win_set_option(win, "cursorline", true)
    end, {buffer=buf, desc="Teams help"})
    vim.keymap.set("n", "U", function()
      show_unread_only = not show_unread_only
      render_and_bind(all_for_search, all_for_search, false, current_filter or "")
      vim.notify(show_unread_only and "Showing unread chats only" or "Showing all chats", vim.log.levels.INFO)
    end, {buffer=buf, desc="Toggle unread only"})
    vim.keymap.set("n", "M", function()
      vim.g.ms_teams_show_meeting=not vim.g.ms_teams_show_meeting
      render_and_bind(all_for_search, all_for_search, false, current_filter or "")
      vim.notify(vim.g.ms_teams_show_meeting and "Showing meetings" or "Hiding meetings", vim.log.levels.INFO)
    end, {buffer=buf, desc="Toggle show meetings"})
    vim.keymap.set("n", "gS", function()
      show_all_limit = not show_all_limit
      render_and_bind(all_for_search, all_for_search, false, current_filter or "")
      vim.notify(show_all_limit and "Showing all chats" or "Showing top 30 chats", vim.log.levels.INFO)
    end, {buffer=buf, desc="Toggle show more/less chats"})
    vim.keymap.set("n", "R", function()
      vim.notify("refreshing...",vim.log.levels.INFO)
      require("ms-teams.graph").list_chats(function(nc,err)
        if err then vim.notify("refresh failed: "..err,vim.log.levels.ERROR); return end
        -- Preservar members ya enriquecidos del cache anterior si el nuevo chat no los trae
        local old_members_by_id = {}
        for _, oc in ipairs(all_for_search or {}) do
          if oc ~= vim.NIL and nv(oc.id) and oc.members and type(oc.members) == "table" and #oc.members > 0 then
            old_members_by_id[nv(oc.id)] = oc.members
          end
        end
        for _, c in ipairs(nc or {}) do
          if c ~= vim.NIL and nv(c.id) and (not c.members or type(c.members) ~= "table" or #c.members == 0) then
            if old_members_by_id[nv(c.id)] then
              c.members = old_members_by_id[nv(c.id)]
            end
          end
        end
        cache.save("chats",{chats=nc})
        require("ms-teams.graph").list_teams(function(nt, err2)
          if nt and #nt>0 and not err2 then
            teams_data = nt
            cache.save("teams",{teams=nt})
            load_all_channels(nt, function()
              cache.save("teams_channels", channels_map)
              render_and_bind(nc,nc,false,"")
              vim.notify(string.format("refreshed %d chats + %d teams", #nc, #nt), vim.log.levels.INFO)
            end)
          else
            render_and_bind(nc,nc,false,"")
            vim.notify(string.format("refreshed %d chats", #nc), vim.log.levels.INFO)
          end
        end)
      end,{all=true,limit=100})
    end, {buffer=buf})
    vim.keymap.set("n", "<C-x>", function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local ok, line_to_chat = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_line_to_chat")
      if not ok or not line_to_chat[lnum] then vim.notify("no chat on this line", vim.log.levels.WARN); return end
      local chat = line_to_chat[lnum]
      local cid = nv(chat.id)
      if not cid then vim.notify("chat sin id", vim.log.levels.WARN); return end
      if cid == "48:notes" then vim.notify("Notes [48:notes] no se puede ocultar", vim.log.levels.WARN); return end
      local name = format_chat(chat)
      vim.ui.input({ prompt = string.format('Are you sure you want to hide "%s"? (y/N): ', name) }, function(ans)
        if not ans or ans:lower() ~= "y" then vim.notify("cancelled", vim.log.levels.INFO); return end
        vim.notify("hiding " .. name .. "...", vim.log.levels.INFO)
        require("ms-teams.graph").hide_chat(cid, function(_, err)
          -- persiste local aunque falle Graph (Chat.Read sin ReadWrite)
          local hidden2 = load_hidden()
          local already=false; for _,id in ipairs(hidden2) do if id==cid then already=true; break end end
          if not already then table.insert(hidden2, cid); save_hidden(hidden2) end
          local new_all = {}
          for _,c in ipairs(all_for_search) do if nv(c.id) ~= cid then table.insert(new_all, c) end end
          all_for_search = new_all
          cache.save("chats", { chats = new_all })
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(buf) then
              render_and_bind(new_all, new_all, false, current_filter or "")
              if err then
                vim.notify('hidden locally "' .. name .. '" (Graph hide necesita Chat.ReadWrite → oculto persistente fuera del top 20, R lo respeta)', vim.log.levels.WARN)
              else
                vim.notify('hidden "' .. name .. '" (Graph hideForUser)', vim.log.levels.INFO)
              end
            end
          end)
        end)
      end)
    end, { buffer=buf, desc="Hide chat (Graph POST /chats/{id}/hide)" })
    vim.keymap.set("n", "q", function() vim.api.nvim_buf_delete(buf,{force=true}) end,{buffer=buf})
    -- per-buffer group with clear: render_and_bind re-registers keymaps on every
    -- render; without clear, one :e would fire N accumulated handlers (Nx logs)
    local list_grp = vim.api.nvim_create_augroup("MsTeamsListRefresh" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("BufReadCmd", { group = list_grp, buffer = buf, callback = function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      if #lines == 1 and lines[1] == "" then
        local ok2, old_all2 = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_all_chats")
        if ok2 and old_all2 and #old_all2 > 0 then
          render_and_bind(old_all2, old_all2, true, current_filter or "")
        end
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local ok, old_all = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_all_chats")
        vim.notify("refreshing...", vim.log.levels.INFO)
        require("ms-teams.graph").list_chats(function(nc, err)
          if err then vim.notify("refresh failed: " .. err, vim.log.levels.ERROR); return end
          -- Preservar members ya enriquecidos si el nuevo fetch no los trae
          local old_mem = {}
          if ok and old_all then
            for _, oc in ipairs(old_all) do
              if oc ~= vim.NIL and nv(oc.id) and oc.members and type(oc.members) == "table" and #oc.members > 0 then
                old_mem[nv(oc.id)] = oc.members
              end
            end
          end
          for _, c in ipairs(nc or {}) do
            if c ~= vim.NIL and nv(c.id) and (not c.members or type(c.members) ~= "table" or #c.members == 0) then
              if old_mem[nv(c.id)] then c.members = old_mem[nv(c.id)] end
            end
          end
          cache.save("chats", { chats = nc })
          vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(buf) then return end
            local changed = true
            if ok and old_all and #nc == #old_all then
              changed = false
              for i, c in ipairs(nc) do
                local oid = old_all[i] and old_all[i].id
                if c.id ~= oid then changed = true; break end
              end
            end
            if changed then
              render_and_bind(nc, nc, false, "")
              vim.notify(string.format("refreshed %d chats", #nc), vim.log.levels.INFO)
            else
              vim.notify("already up to date", vim.log.levels.INFO)
            end
          end)
        end, { all = true, limit = 100 })
      end)
    end })
  end
  -- expose render fn immediately (before any list_chats call) so background
  -- refreshes (e.g. after davmail re-auth, watch poll) can update even
  -- never-rendered buffers stuck on "Loading chats..."; coalesced as
  -- background so it merges with any in-flight enrichment paint
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_render_and_bind", function(a, b, c)
    request_render(a, b, c, nil, { background = true })
  end)
  -- markdown-style folds for the list buffer (za/zo/zc on # / ## headers).
  -- foldmethod is window-local: apply to the current window now and to any
  -- window showing this buffer later via BufWinEnter.
  local function apply_list_folds(win)
    if not win or win == -1 or not vim.api.nvim_win_is_valid(win) then return end
    pcall(vim.api.nvim_set_option_value, "foldmethod", "expr", { win = win })
    pcall(vim.api.nvim_set_option_value, "foldexpr", "v:lua.require'ms-teams.ui'.list_fold_expr(v:lnum)", { win = win })
    pcall(vim.api.nvim_set_option_value, "foldenable", true, { win = win })
    pcall(vim.api.nvim_set_option_value, "foldlevel", 99, { win = win })
  end
  -- separate group (not cleared by per-render group above): keep folds when
  -- this buffer is displayed in any window (splits, revisits)
  local fold_grp = vim.api.nvim_create_augroup("MsTeamsListFolds" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", { group = fold_grp, buffer = buf, callback = function()
    for _, w in ipairs(vim.fn.win_findbuf(buf)) do apply_list_folds(w) end
  end })
  if cached and cached.chats and #cached.chats>0 then
    set_list_lines({"# Teams chats (cached)","", "Loading chats...",""})
    vim.api.nvim_win_set_buf(0, buf)
    apply_list_folds(vim.api.nvim_get_current_win())
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        render_and_bind(cached.chats, cached.chats, true)
      end
    end)
    vim.defer_fn(function()
      require("ms-teams.graph").list_chats(function(new_chats,err)
        if err or not new_chats then return end
        local changed=false
        if #new_chats ~= #cached.chats then changed=true
        else
          for i,c in ipairs(new_chats) do
            if c.id ~= cached.chats[i].id or c.lastUpdatedDateTime ~= cached.chats[i].lastUpdatedDateTime then changed=true; break end
          end
        end
        if changed then
          cache.save("chats",{chats=new_chats})
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find("ms%-teams://.*chats") then
              vim.notify("chats updated (press R)",vim.log.levels.INFO)
            end
          end)
        end
      end,{all=true,limit=100})
    end,100)
    return
  end
  set_list_lines({"# Teams chats","","Loading chats...",""})
  vim.api.nvim_win_set_buf(0, buf)
  apply_list_folds(vim.api.nvim_get_current_win())
  graph.list_chats(function(chats, err)
    if err then vim.notify("ms-teams list_chats: "..err,vim.log.levels.ERROR); return end
    -- Preservar members si venían de cache anterior
    local old_cached = cache.load("chats", 3600)
    if old_cached and old_cached.chats then
      local mem_map = {}
      for _, oc in ipairs(old_cached.chats) do
        if oc ~= vim.NIL and nv(oc.id) and oc.members and type(oc.members) == "table" and #oc.members > 0 then
          mem_map[nv(oc.id)] = oc.members
        end
      end
      for _, c in ipairs(chats or {}) do
        if c ~= vim.NIL and nv(c.id) and (not c.members or type(c.members) ~= "table" or #c.members == 0) then
          if mem_map[nv(c.id)] then c.members = mem_map[nv(c.id)] end
        end
      end
    end
    -- asegura 48:notes (self real con 123/hola + link 19/01/2024) aunque /me/chats no lo pagina con limit 100
    local has_notes = false
    for _,c in ipairs(chats or {}) do if nv(c.id)=="48:notes" then has_notes=true; break end end
    local function finish(all)
      vim.schedule(function()
        render_and_bind(all,all,false)
        cache.save("chats",{chats=all})
      end)
    end
    if has_notes then finish(chats); return end
    require("ms-teams.graph").get_chat("48:notes", function(note, err2)
      if note and not err2 then table.insert(chats, 1, note) end
      finish(chats)
    end)
  end, {all=true,limit=100})
end

function M.update_chat_list_unread_state(chat_id, is_unread)
  -- TEMPDEBUG: who clears what
  do
    local tb = debug.traceback(nil, 2) or ""
    local caller = tb:match("[^\n]*\n%s*([^\n]*)") or ""
    pcall(vim.fn.writefile, { string.format("%s update id=%s unread=%s caller=%s", os.date("%H:%M:%S"), tostring(chat_id):sub(1, 20), tostring(is_unread), caller:sub(1, 120)) }, "/tmp/ms_unread.log", "a")
  end
  local ns = vim.api.nvim_create_namespace("ms_teams_unread")
  local hl_group = get_unread_hl_group()
  local now_iso = os.date("!%Y-%m-%dT%H:%M:%SZ")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find("ms%-teams://.*chats") then
      local ok_map, line_to_chat = pcall(vim.api.nvim_buf_get_var, b, "ms_teams_line_to_chat")
      if ok_map and line_to_chat then
        for lnum, c in pairs(line_to_chat) do
          if nv(c.id) == chat_id then
            -- Update local chat viewpoint object inside line_to_chat
            c.viewpoint = c.viewpoint or {}
            if c.viewpoint == vim.NIL then c.viewpoint = {} end
            if is_unread then
              c.viewpoint.lastMessageReadDateTime = "1970-01-01T00:00:00Z"
            else
              c.viewpoint.lastMessageReadDateTime = now_iso
            end
            vim.api.nvim_buf_clear_namespace(b, ns, lnum - 1, lnum)
            if is_unread then
              vim.api.nvim_buf_add_highlight(b, ns, hl_group, lnum - 1, 0, eol_col(b, lnum))
            end
          end
        end
      end
      -- Also update Teams section channel/team lines (channels are not in
      -- line_to_chat; their unread state lives in ms_teams_channel_unread)
      local ok_entry, line_to_entry = pcall(vim.api.nvim_buf_get_var, b, "ms_teams_line_to_entry")
      if ok_entry and type(line_to_entry) == "table" then
        local ok_chan, chan_map = pcall(vim.api.nvim_buf_get_var, b, "ms_teams_channel_unread")
        if not (ok_chan and type(chan_map) == "table") then chan_map = {} end
        chan_map[chat_id] = is_unread
        pcall(vim.api.nvim_buf_set_var, b, "ms_teams_channel_unread", chan_map)
        local teams_seen = {}
        for lnum, e in pairs(line_to_entry) do
          if type(e) == "table" and e.type == "channel" and e.channel and nv(e.channel.id) == chat_id then
            vim.api.nvim_buf_clear_namespace(b, ns, lnum - 1, lnum)
            if is_unread then
              vim.api.nvim_buf_add_highlight(b, ns, hl_group, lnum - 1, 0, eol_col(b, lnum))
            end
            if e.team and nv(e.team.id) then teams_seen[nv(e.team.id)] = true end
          end
        end
        -- recompute parent team headers: lit if any of their channels is unread
        for tid, _ in pairs(teams_seen) do
          for lnum, e in pairs(line_to_entry) do
            if type(e) == "table" and e.type == "team" and e.team and nv(e.team.id) == tid then
              local team_unread = false
              for _, e2 in pairs(line_to_entry) do
                if type(e2) == "table" and e2.team and nv(e2.team.id) == tid then
                  if e2.type == "channel" and e2.channel then
                    local cid2 = nv(e2.channel.id)
                    if cid2 and chan_map[cid2] then team_unread = true; break end
                  elseif e2.type == "chat" and e2.chat and nv(e2.chat.chatType) == "channel" then
                    if has_unread(e2.chat) then team_unread = true; break end
                  end
                end
              end
              vim.api.nvim_buf_clear_namespace(b, ns, lnum - 1, lnum)
              if team_unread then
                vim.api.nvim_buf_add_highlight(b, ns, hl_group, lnum - 1, 0, eol_col(b, lnum))
              end
            end
          end
        end
      end
      -- Also update ms_teams_all_chats list if present
      local ok_all, all_chats = pcall(vim.api.nvim_buf_get_var, b, "ms_teams_all_chats")
      if ok_all and all_chats then
        for _, c in ipairs(all_chats) do
          if nv(c.id) == chat_id then
            c.viewpoint = c.viewpoint or {}
            if c.viewpoint == vim.NIL then c.viewpoint = {} end
            if is_unread then
              c.viewpoint.lastMessageReadDateTime = "1970-01-01T00:00:00Z"
            else
              c.viewpoint.lastMessageReadDateTime = now_iso
            end
          end
        end
      end
    end
  end
  -- Persist to chats cache so reopening MSTeamsChats keeps the new state
  local ok_cache, cache = pcall(require, "ms-teams.cache")
  if ok_cache and cache then
    local ok_load, loaded = pcall(cache.load, "chats")
    if ok_load and loaded and loaded.chats then
      local changed = false
      for _, c in ipairs(loaded.chats) do
        if nv(c.id) == chat_id then
          c.viewpoint = c.viewpoint or {}
          if c.viewpoint == vim.NIL then c.viewpoint = {} end
          local new_val = is_unread and "1970-01-01T00:00:00Z" or now_iso
          if nv(c.viewpoint.lastMessageReadDateTime) ~= new_val then
            c.viewpoint.lastMessageReadDateTime = new_val
            changed = true
          end
        end
      end
      if changed then pcall(cache.save, "chats", loaded) end
    end
  end
end

-- Diagnose unread state for chats matching substr across buf vars, disk
-- cache and fresh fetch. Usage: :MSTeamsDebugUnread 9ac8b6e1
function M.debug_unread_state(substr)
  substr = substr or ""
  local lines = {}
  local function snap_into(t, tag, chat)
    if not chat or chat == vim.NIL then return end
    local id = nv(chat.id)
    if not id or (substr ~= "" and not id:find(substr, 1, true)) then return end
    if #t >= 12 then return end
    local cache = require("ms-teams.cache")
    local override = cache.get_last_read(id)
    local vp = nv(chat.viewpoint)
    local lr = vp and nv(vp.lastMessageReadDateTime)
    local pv = nv(chat.lastMessagePreview)
    local lu = pv and nv(pv.createdDateTime)
    local from = pv and nv(pv.from) and nv(nv(pv.from).user)
    table.insert(t, string.format("%s %s unread=%s override=%s vp=%s prev=%s from=%s",
      tag, id:sub(1, 20), tostring(has_unread(chat)), tostring(override),
      tostring(lr), tostring(lu), from and (nv(from.displayName) or "?") or "nil"))
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find("ms%-teams://.*chats") then
      local ok, allc = pcall(vim.api.nvim_buf_get_var, b, "ms_teams_all_chats")
      if ok and type(allc) == "table" then
        for _, c in ipairs(allc) do snap_into(lines, "bufvar", c) end
      end
    end
  end
  local okc, cc = pcall(require("ms-teams.cache").load, "chats")
  if okc and cc and cc.chats then
    for _, c in ipairs(cc.chats) do snap_into(lines, "disk", c) end
  end
  vim.notify(table.concat(lines, "\n") .. "\n(fetching fresh...)", vim.log.levels.INFO)
  require("ms-teams.graph").list_chats(function(chats, err)
    vim.schedule(function()
      if err then vim.notify("debug fetch err: " .. tostring(err):sub(1, 120), vim.log.levels.WARN); return end
      local out2 = {}
      for _, c in ipairs(chats or {}) do snap_into(out2, "fresh", c) end
      vim.notify(#out2 > 0 and table.concat(out2, "\n") or "(no match in fresh fetch)", vim.log.levels.INFO)
    end)
  end, { all = true, limit = 200 })
end

-- Reconcile open list buffers' highlights with fresh server data, in both
-- directions. The watch only ever lights lines up; without this, chats read
-- elsewhere keep stale highlights (and newly-read ones stay lit) until R.
function M.sync_list_highlights(fresh_chats)
  if not fresh_chats or #fresh_chats == 0 then return end
  local fresh_by_id = {}
  for _, c in ipairs(fresh_chats) do
    if c ~= vim.NIL and nv(c.id) then fresh_by_id[nv(c.id)] = c end
  end
  local ns = vim.api.nvim_create_namespace("ms_teams_unread")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find("ms%-teams://.*chats") then
      local ok_map, line_to_chat = pcall(vim.api.nvim_buf_get_var, b, "ms_teams_line_to_chat")
      if ok_map and type(line_to_chat) == "table" then
        local ok_marks, marks = pcall(vim.api.nvim_buf_get_extmarks, b, ns, { 0, 0 }, { -1, -1 }, {})
        local lit = {}
        if ok_marks and marks then
          for _, m in ipairs(marks) do lit[m[1] + 1] = true end
        end
        for lnum, c in pairs(line_to_chat) do
          local cid = nv(c.id)
          local fresh = cid and fresh_by_id[cid]
          if fresh then
            local want = has_unread(fresh)
            if want ~= lit[lnum] then
              if not want then
                -- only clear on solid evidence: a missing preview means
                -- incomplete data, not "read" (would poison viewpoint+cache)
                local pv = nv(fresh.lastMessagePreview)
                if not (pv and pv ~= vim.NIL and nv(pv.createdDateTime)) then
                  goto continue_sync
                end
              end
              M.update_chat_list_unread_state(cid, want)
            end
            ::continue_sync::
          end
        end
      end
    end
  end
end

function M.refresh_chats_background(cb)
  vim.notify("MSTeams: actualizando listado de chats en segundo plano...", vim.log.levels.INFO)
  local cache = require("ms-teams.cache")
  local graph = require("ms-teams.graph")
  graph.list_chats(function(new_chats, err)
    if err or not new_chats then
      vim.schedule(function()
        vim.notify("MSTeams: error al actualizar listado de chats: " .. tostring(err), vim.log.levels.WARN)
        if cb then cb(nil, err) end
      end)
      return
    end

    -- Preserve / fetch 48:notes if needed
    local has_notes = false
    for _, c in ipairs(new_chats) do
      if nv(c.id) == "48:notes" then has_notes = true; break end
    end

    local function finish_update(all_chats)
      cache.save("chats", { chats = all_chats })
      vim.schedule(function()
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find("ms%-teams://.*chats") then
            local ok_render, render_fn = pcall(vim.api.nvim_buf_get_var, b, "ms_teams_render_and_bind")
            if ok_render and type(render_fn) == "function" then
              render_fn(all_chats, all_chats, false)
            end
          end
        end
        vim.notify("MSTeams: listado de chats actualizado", vim.log.levels.INFO)
        if cb then cb(all_chats, nil) end
      end)
    end

    if has_notes then
      finish_update(new_chats)
    else
      graph.get_chat("48:notes", function(note, _)
        if note then table.insert(new_chats, 1, note) end
        finish_update(new_chats)
      end)
    end
  end, { all = true, limit = 100 })
end

-- search helpers: jump to message after loading history if needed
local function jump_to_message(detail_buf, lnum, query, keep_focus)
  if not vim.api.nvim_buf_is_valid(detail_buf) then return end
  local cur_win = vim.api.nvim_get_current_win()
  local win = vim.fn.bufwinid(detail_buf)
  if win == -1 and keep_focus then
    -- detail hidden: don't disturb the layout; highlight now (buffer ops
    -- work hidden) and place the cursor on first display (latest jump wins)
    vim.api.nvim_create_augroup("MsTeamsPendingJump", { clear = true })
    vim.api.nvim_create_autocmd("BufWinEnter", { group = "MsTeamsPendingJump", buffer = detail_buf, once = true,
      callback = function()
        local w = vim.fn.bufwinid(detail_buf)
        if w ~= -1 then
          pcall(vim.api.nvim_win_set_cursor, w, { lnum, 0 })
          pcall(vim.api.nvim_win_call, w, function() vim.cmd("normal! zz") end)
        end
      end })
  else
    if win == -1 then
      vim.api.nvim_win_set_buf(0, detail_buf)
      win = vim.api.nvim_get_current_win()
    elseif not keep_focus then
      vim.api.nvim_set_current_win(win)
    end
    local line_count = vim.api.nvim_buf_line_count(detail_buf)
    if lnum < 1 or lnum > line_count then
      vim.notify("ms-teams: message position changed (buffer re-rendered), press <CR> again", vim.log.levels.WARN)
      return
    end
    pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
    pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! zz") end)
    -- TEMPDEBUG cursor trace
    pcall(vim.fn.writefile, { string.format("%s jump_to_message buf=%d lnum=%d keep=%s", os.date("%H:%M:%S"), detail_buf, lnum, tostring(keep_focus)) }, "/tmp/ms_cursor.log", "a")
    if keep_focus and vim.api.nvim_win_is_valid(cur_win) and cur_win ~= win then
      vim.api.nvim_set_current_win(cur_win)
    end
  end
  vim.api.nvim_buf_clear_namespace(detail_buf, search_ns, 0, -1)
  if query and query ~= "" then
    local hl = require("ms-teams.config").options.highlights and require("ms-teams.config").options.highlights.search or "DiagnosticUnderlineError"
    local sensitive = is_smart_case_sensitive(query)
    local needle = sensitive and query or query:lower()
    -- highlight every occurrence in the whole message block (header + body),
    -- stopping at the next message header, divider or footer
    local last = vim.api.nvim_buf_line_count(detail_buf)
    local stop = last + 1
    for i = lnum + 1, last do
      local l = vim.api.nvim_buf_get_lines(detail_buf, i - 1, i, false)[1] or ""
      if l:match("^● ") or l:match("^%-%-%-") or l:match("^Chat:") or l:match("^Hints:") or l:match("^# ") then
        stop = i
        break
      end
    end
    local found_any = false
    for i = lnum, math.min(stop - 1, last) do
      local line = vim.api.nvim_buf_get_lines(detail_buf, i - 1, i, false)[1] or ""
      local hay = sensitive and line or line:lower()
      local from = 1
      while true do
        local s, e = hay:find(needle, from, true)
        if not s then break end
        found_any = true
        pcall(vim.api.nvim_buf_add_highlight, detail_buf, search_ns, hl, i - 1, s - 1, e)
        from = e + 1
        if from > #hay then break end
      end
    end
    if not found_any then
      pcall(vim.api.nvim_buf_add_highlight, detail_buf, search_ns, hl, lnum - 1, 0, eol_col(detail_buf, lnum))
    end
    -- always highlight the sender name on the header line too (● **Name** (date):)
    local header = vim.api.nvim_buf_get_lines(detail_buf, lnum - 1, lnum, false)[1] or ""
    local ns_, ne_ = header:find("%*%*.-%*%*")
    if ns_ and ne_ - 2 > ns_ + 1 then
      pcall(vim.api.nvim_buf_add_highlight, detail_buf, search_ns, hl, lnum - 1, ns_ + 1, ne_ - 2)
    end
  end
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(detail_buf) then
      vim.api.nvim_buf_clear_namespace(detail_buf, search_ns, 0, -1)
    end
  end, 4000)
end

-- re-render detail buffer silently (same buffer, no window/cursor changes);
-- returns false when unavailable so callers can fall back to show_messages
local function silent_rerender(detail_buf, msgs, nextLink)
  if not detail_buf or not vim.api.nvim_buf_is_valid(detail_buf) then return false end
  local n = vim.api.nvim_buf_get_name(detail_buf)
  if not n:find("ms-teams://chat", 1, true) then return false end
  local ok_r, render_fn = pcall(vim.api.nvim_buf_get_var, detail_buf, "ms_teams_detail_render")
  if not (ok_r and type(render_fn) == "function") then return false end
  -- force: synchronous render so the caller can read a fresh map right away
  -- (coalesced/deferred renders would leave a stale map behind)
  render_fn(msgs, nextLink or "", { no_cursor = true, force = true })
  return true
end

local function ensure_message_and_jump(chat, detail_buf, target_id, query, keep_focus)
  -- resolve freshest detail buffer (duplicates may exist from older renders):
  -- prefer the one whose map already has the target, else the fullest map
  local chat_id0 = nv(chat.id)
  local safe0 = chat_id0 and chat_id0:gsub("[^%w%-_:.]", "_"):sub(1, 60) or nil
  if safe0 then
    local best, best_score = nil, -1
    local function consider(b)
      local okm, mm = pcall(vim.api.nvim_buf_get_var, b, "ms_teams_id_to_lnum")
      if not (okm and type(mm) == "table") then return end
      local score = 0
      if mm[target_id] then score = 100000 end
      for _ in pairs(mm) do score = score + 1 end
      if score > best_score then best, best_score = b, score end
    end
    if detail_buf and vim.api.nvim_buf_is_valid(detail_buf) then consider(detail_buf) end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and b ~= detail_buf then
        local n = vim.api.nvim_buf_get_name(b)
        if n:find("ms-teams://chat", 1, true) and n:find(safe0, 1, true) then consider(b) end
      end
    end
    if best then detail_buf = best end
  end
  local ok, id_map = pcall(vim.api.nvim_buf_get_var, detail_buf, "ms_teams_id_to_lnum")
  if ok and id_map and id_map[target_id] then
    jump_to_message(detail_buf, id_map[target_id], query, keep_focus)
    return
  end
  -- need to load older history until found
  local chat_id = nv(chat.id)
  local cache = require("ms-teams.cache")
  local safe_id = chat_id:gsub("[^%w%-_:.]", "_"):sub(1, 60)
  local cache_key = "messages_" .. safe_id
  local is_channel = nv(chat.chatType) == "channel" and nv(chat.teamId) ~= nil
  local team_id = nv(chat.teamId)
  local function do_list(id, cb, nl)
    if is_channel then require("ms-teams.graph").list_channel_messages(team_id, id, cb, nl)
    else require("ms-teams.graph").list_messages(id, cb, nl) end
  end
  local ok2, msgs = pcall(vim.api.nvim_buf_get_var, detail_buf, "ms_teams_raw_msgs")
  local ok3, nl = pcall(vim.api.nvim_buf_get_var, detail_buf, "ms_teams_nextLink")
  msgs = (ok2 and msgs) or {}
  local nextLink = (ok3 and nl) or ""
  if not nextLink or nextLink == "" then
    vim.notify("message not in loaded history (no more pages)", vim.log.levels.WARN)
    return
  end
  vim.notify("loading history to find message...", vim.log.levels.INFO)
  local seen = {}
  for _, m in ipairs(msgs) do if m ~= vim.NIL and nv(m.id) then seen[nv(m.id)] = true end end
  local function fetch_next(nl_cur)
    do_list(chat_id, function(more, err, next2)
      if err then vim.notify("load failed: " .. tostring(err), vim.log.levels.ERROR); return end
      if not more or #more == 0 then vim.notify("message not found in full history", vim.log.levels.WARN); return end
      for _, m in ipairs(more) do
        if m ~= vim.NIL and nv(m.id) and not seen[nv(m.id)] then table.insert(msgs, m); seen[nv(m.id)] = true end
      end
      cache.save(cache_key, { messages = msgs, nextLink = next2 or "" })
      local found = false
      for _, m in ipairs(more) do if nv(m.id) == target_id then found = true; break end end
      -- keep paging silently; render only once at the end (no per-page flicker)
      if not found and next2 and next2 ~= "" then
        fetch_next(next2)
        return
      end
      vim.schedule(function()
        -- single silent re-render into the same buffer: no window changes,
        -- no cursor moves, no end-of-buffer scroll (map is fresh right after)
        if silent_rerender(detail_buf, msgs, next2) then
          local ok4, new_map = pcall(vim.api.nvim_buf_get_var, detail_buf, "ms_teams_id_to_lnum")
          if ok4 and new_map and new_map[target_id] then
            jump_to_message(detail_buf, new_map[target_id], query, keep_focus)
          else
            vim.notify("message not found after loading", vim.log.levels.WARN)
          end
          return
        end
        -- fallback for buffers rendered before silent re-render existed;
        -- force re-render via show_messages (reuses cache); when keeping
        -- focus in results, steer the hijack at the detail window if visible
        if keep_focus then
          local dw = vim.fn.bufwinid(detail_buf)
          if dw ~= -1 then pcall(vim.api.nvim_set_current_win, dw) end
        end
        M.show_messages(chat, "current")
        vim.defer_fn(function()
          -- locate the chat buffer whose map actually contains the target
          -- (there may be duplicate buffers from older renders)
          local target_buf = nil
          local fallback_buf = (detail_buf and vim.api.nvim_buf_is_valid(detail_buf)) and detail_buf or nil
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(b) then
              local n = vim.api.nvim_buf_get_name(b)
              if n:find("ms-teams://chat", 1, true) and n:find(safe_id, 1, true) then
                local okm, mm = pcall(vim.api.nvim_buf_get_var, b, "ms_teams_id_to_lnum")
                if okm and type(mm) == "table" then
                  if mm[target_id] then target_buf = b; break end
                  if not fallback_buf then fallback_buf = b end
                end
              end
            end
          end
          target_buf = target_buf or fallback_buf or detail_buf
          local ok4, new_map = pcall(vim.api.nvim_buf_get_var, target_buf, "ms_teams_id_to_lnum")
          if ok4 and new_map and new_map[target_id] then
            jump_to_message(target_buf, new_map[target_id], query, keep_focus)
          elseif next2 and next2 ~= "" and not found then
            -- continue loading if still not found and more pages exist
            -- need to fetch next page with updated nextLink
            -- we already have msgs accumulated in closure, continue
            fetch_next(next2)
          elseif not found then
            vim.notify("message not found after loading page", vim.log.levels.WARN)
          end
        end, 400)
      end)
    end, nl_cur)
  end
  fetch_next(nextLink)
end

-- ensure a set of message ids is loaded in the detail buffer (pages history
-- as needed, single re-render at the end); cb(ok, buf)
local function ensure_messages_loaded(chat, detail_buf, target_ids, cb)
  local chat_id = nv(chat.id)
  if not chat_id then cb(false, detail_buf); return end
  local cache = require("ms-teams.cache")
  local safe_id = chat_id:gsub("[^%w%-_:.]", "_"):sub(1, 60)
  local cache_key = "messages_" .. safe_id
  local is_channel = nv(chat.chatType) == "channel" and nv(chat.teamId) ~= nil
  local team_id = nv(chat.teamId)
  local function do_list(id, dcb, nl)
    if is_channel then require("ms-teams.graph").list_channel_messages(team_id, id, dcb, nl)
    else require("ms-teams.graph").list_messages(id, dcb, nl) end
  end
  local function id_map_of(b)
    if not b or not vim.api.nvim_buf_is_valid(b) then return nil end
    local ok, m = pcall(vim.api.nvim_buf_get_var, b, "ms_teams_id_to_lnum")
    if ok and type(m) == "table" then return m end
    return nil
  end
  -- prefer the chat buffer already holding most wanted ids (freshest render)
  local function best_buf()
    local best, best_score = nil, -1
    local function consider(b)
      local m = id_map_of(b)
      if not m then return end
      local s = 0
      for _, id in ipairs(target_ids) do if m[id] then s = s + 1 end end
      if s > best_score then best, best_score = b, s end
    end
    if detail_buf and vim.api.nvim_buf_is_valid(detail_buf) then consider(detail_buf) end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
        local n = vim.api.nvim_buf_get_name(b)
        if n:find("ms-teams://chat", 1, true) and n:find(safe_id, 1, true) and b ~= detail_buf then
          consider(b)
        end
      end
    end
    return best
  end
  local function missing_in(id_map)
    local miss = {}
    for _, id in ipairs(target_ids) do
      if not (id_map and id_map[id]) then table.insert(miss, id) end
    end
    return miss
  end
  if #target_ids == 0 then cb(false, detail_buf); return end
  local buf0 = best_buf()
  if buf0 and #missing_in(id_map_of(buf0)) == 0 then cb(true, buf0); return end
  local msgs = {}
  local nextLink = ""
  if buf0 then
    local ok2, m2 = pcall(vim.api.nvim_buf_get_var, buf0, "ms_teams_raw_msgs")
    if ok2 and type(m2) == "table" then msgs = m2 end
    local ok3, nl0 = pcall(vim.api.nvim_buf_get_var, buf0, "ms_teams_nextLink")
    if ok3 and type(nl0) == "string" then nextLink = nl0 end
  end
  if (not nextLink or nextLink == "") and #msgs > 0 then
    vim.notify("some messages not in loaded history (no more pages)", vim.log.levels.WARN)
    cb(false, buf0 or detail_buf)
    return
  end
  vim.notify("loading history for quickfix...", vim.log.levels.INFO)
  local seen = {}
  for _, m in ipairs(msgs) do if m ~= vim.NIL and nv(m.id) then seen[nv(m.id)] = true end end
  local pages = 0
  local max_pages = 20
  local function fetch_next(nl_cur)
    pages = pages + 1
    do_list(chat_id, function(more, err, next2)
      if err then vim.notify("load failed: " .. tostring(err), vim.log.levels.ERROR); cb(false, best_buf() or detail_buf); return end
      if not more or #more == 0 then vim.notify("history exhausted, some messages missing", vim.log.levels.WARN); cb(false, best_buf() or detail_buf); return end
      for _, m in ipairs(more) do
        if m ~= vim.NIL and nv(m.id) and not seen[nv(m.id)] then table.insert(msgs, m); seen[nv(m.id)] = true end
      end
      local still_missing = false
      for _, id in ipairs(target_ids) do if not seen[id] then still_missing = true; break end end
      if (not still_missing) or not (next2 and next2 ~= "") or pages >= max_pages then
        cache.save(cache_key, { messages = msgs, nextLink = next2 or "" })
        vim.schedule(function()
          -- silent background re-render: no window changes, no cursor moves
          local rbuf = best_buf() or detail_buf
          if silent_rerender(rbuf, msgs, next2) then
            local fb = best_buf() or rbuf
            if #missing_in(id_map_of(fb)) == 0 then cb(true, fb)
            else vim.notify("some messages not found after loading", vim.log.levels.WARN); cb(false, fb) end
            return
          end
          M.show_messages(chat, "current")
          vim.defer_fn(function()
            local fb = best_buf()
            if #missing_in(id_map_of(fb)) == 0 then cb(true, fb)
            else vim.notify("some messages not found after loading", vim.log.levels.WARN); cb(false, fb or detail_buf) end
          end, 400)
        end)
        return
      end
      vim.notify(string.format("loading history... (%d msgs)", #msgs), vim.log.levels.INFO)
      fetch_next(next2)
    end, nl_cur)
  end
  fetch_next(nextLink ~= "" and nextLink or nil)
end

local function send_msgs_to_qflist(chat, detail_buf, msgs, query)
  local ids, seen_ids, ordered = {}, {}, {}
  for _, m in ipairs(msgs) do
    if m ~= vim.NIL and type(m) == "table" then
      local id = nv(m.id)
      if id and not seen_ids[id] then seen_ids[id] = true; table.insert(ids, id); table.insert(ordered, m) end
    end
  end
  if #ids == 0 then vim.notify("no messages to send to quickfix", vim.log.levels.WARN); return end
  ensure_messages_loaded(chat, detail_buf, ids, function(ok, buf)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then vim.notify("chat buffer unavailable", vim.log.levels.WARN); return end
    local okm, id_map = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_id_to_lnum")
    if not okm or type(id_map) ~= "table" then id_map = {} end
    local sensitive = is_smart_case_sensitive(query or "")
    local needle = sensitive and (query or "") or (query or ""):lower()
    local qf = {}
    for _, m in ipairs(ordered) do
      local id = nv(m.id)
      local lnum = id and id_map[id] or nil
      if lnum then
        local f = nv(m.from) and nv(m.from.user) and nv(m.from.user.displayName) or "unknown"
        if f == vim.NIL then f = "unknown" end
        local dt = format_date(nv(m.createdDateTime) or "")
        local plain = extract_message_plain(m)
        local snippet = (make_snippet(plain, query or ""))
        local text = string.format("%s (%s): %s", tostring(f), tostring(dt), tostring(snippet)):gsub("\n", " ")
        local col = 1
        local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
        if needle ~= "" then
          local hay = sensitive and line or line:lower()
          local s = hay:find(needle, 1, true)
          if s then col = s end
        end
        table.insert(qf, { bufnr = buf, lnum = lnum, col = col, text = text })
      end
    end
    if #qf == 0 then vim.notify("no loaded matches for quickfix", vim.log.levels.WARN); return end
    vim.fn.setqflist(qf, "r")
    vim.fn.setqflist({}, "a", { title = string.format('ms-teams search "%s"', query or "") })
    vim.cmd("copen")
  end)
end

-- open the results buffer immediately (vertical split) with a placeholder;
-- results are filled in later via fill_search_buffer
local function open_search_buffer(chat, query, detail_buf)
  local title = format_chat(chat) or nv(chat.topic) or nv(chat.chatType) or nv(chat.id) or "chat"
  local safe_name = to_ascii(title):gsub("[^%w%-_ %.]", "_"):gsub("%s+", "-"):sub(1, 30)
  local safe_q = query:gsub("[^%w%-_]", "_"):sub(1, 20)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  set_listed_scratch(buf, "ms-teams://search/" .. safe_name .. "/" .. safe_q)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Search \"" .. query .. "\" in " .. title, "", "Searching...", "" })
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_chat", chat)
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_chat_buf", detail_buf)
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_query", query)
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_loading", true)
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_line_map", {})
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_results", {})
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, buf)
  local function search_map()
    local ok, m = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_search_line_map")
    if ok and type(m) == "table" then return m end
    return {}
  end
  local function still_loading()
    local ok, v = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_search_loading")
    return ok and v == true
  end
  local function jump_under_cursor()
    if still_loading() then vim.notify("search still loading...", vim.log.levels.INFO); return end
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local map = search_map()
    local r = map[lnum]
    if not r then
      -- try nearest above
      for i = lnum, 1, -1 do if map[i] then r = map[i]; break end end
    end
    if not r or not r.msg then vim.notify("no match on this line", vim.log.levels.WARN); return end
    local target_id = nv(r.msg.id)
    if not target_id then vim.notify("match has no id", vim.log.levels.WARN); return end
    -- move detail cursor but keep focus in results
    ensure_message_and_jump(chat, detail_buf, target_id, query, true)
  end
  vim.keymap.set("n", "<CR>", jump_under_cursor, { buffer = buf, desc = "Jump to message" })
  -- avoid netrw gx/gf E447 on the ● header lines: jump instead
  vim.keymap.set("n", "gx", jump_under_cursor, { buffer = buf, desc = "Jump to message" })
  vim.keymap.set("n", "gf", jump_under_cursor, { buffer = buf, desc = "Jump to message" })
  vim.keymap.set("n", "<C-q>", function()
    if still_loading() then vim.notify("search still loading...", vim.log.levels.INFO); return end
    local ok_r, stored = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_search_results")
    local msgs = {}
    if ok_r and type(stored) == "table" then
      for _, r in ipairs(stored) do if r and r.msg then table.insert(msgs, r.msg) end end
    end
    if #msgs == 0 then vim.notify("no results to send", vim.log.levels.WARN); return end
    send_msgs_to_qflist(chat, detail_buf, msgs, query)
  end, { buffer = buf, desc = "Send results to quickfix" })
  vim.keymap.set("n", "<Esc>", function() vim.api.nvim_buf_delete(buf, { force = true }) end, { buffer = buf })
  return buf
end

local function set_search_buffer_state(buf, chat, query, body_lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  local title = format_chat(chat) or nv(chat.topic) or nv(chat.chatType) or nv(chat.id) or "chat"
  local lines = { "# Search \"" .. query .. "\" in " .. title, "" }
  for _, l in ipairs(body_lines) do table.insert(lines, l) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_loading", false)
  return true
end

local function fill_search_buffer(buf, chat, query, matches, detail_buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  local title = format_chat(chat) or nv(chat.topic) or nv(chat.chatType) or nv(chat.id) or "chat"
  local lines = { "# Search \"" .. query .. "\" in " .. title .. " — " .. #matches .. " matches", "", "Press <CR> to jump, <C-q> quickfix, gF for telescope, q to close", "" }
  local line_to_match = {}
  for i, r in ipairs(matches) do
    local m = r.msg
    local from = nv(m.from) and nv(m.from.user) and nv(m.from.user.displayName) or "unknown"
    local dt = format_date(nv(m.createdDateTime) or "")
    local snippet = r.snippet or extract_message_plain(m):sub(1, 120)
    local header = string.format("● **%s** (%s):", from, dt)
    table.insert(lines, header)
    local lnum = #lines + 1
    table.insert(lines, "  " .. snippet)
    table.insert(lines, "")
    line_to_match[lnum] = r
    -- also map header line for convenience
    line_to_match[#lines - 2] = r
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_results", matches)
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_chat", chat)
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_chat_buf", detail_buf)
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_query", query)
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_line_map", line_to_match)
  pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_search_loading", false)
  return true
end

function M.search_in_chat(chat, detail_buf)
  local chat_id = nv(chat.id)
  if not chat_id then vim.notify("chat has no id", vim.log.levels.ERROR); return end
  local team_id = nv(chat.teamId)
  vim.ui.input({ prompt = "Search in chat: " }, function(q)
    if q == nil then return end
    q = vim.trim(q)
    if q == "" then vim.notify("empty query", vim.log.levels.WARN); return end
    -- open results buffer immediately with placeholder, fill when results arrive
    local search_buf = open_search_buffer(chat, q, detail_buf)
    require("ms-teams.graph").search_chat_messages(chat_id, q, function(res, err)
      vim.schedule(function()
        if err then
          vim.notify("search failed: " .. tostring(err), vim.log.levels.ERROR)
          set_search_buffer_state(search_buf, chat, q, { "Search failed: " .. tostring(err), "" })
          return
        end
        if not res or #res == 0 then
          set_search_buffer_state(search_buf, chat, q, { "No matches for \"" .. q .. "\"", "" })
          return
        end
        -- build snippets with smart case
        local matches = {}
        for _, m in ipairs(res) do
          if m ~= vim.NIL then
            local plain = extract_message_plain(m)
            local snippet, _, _ = make_snippet(plain, q)
            table.insert(matches, { msg = m, snippet = snippet, plain = plain })
          end
        end
        fill_search_buffer(search_buf, chat, q, matches, detail_buf)
      end)
    end, team_id)
  end)
end

function M.search_in_chat_telescope(chat, detail_buf)
  local chat_id = nv(chat.id)
  if not chat_id then vim.notify("chat has no id", vim.log.levels.ERROR); return end
  local team_id = nv(chat.teamId)
  vim.ui.input({ prompt = "Search in chat (telescope): " }, function(q)
    if q == nil then return end
    q = vim.trim(q)
    if q == "" then return end
    vim.notify("searching \"" .. q .. "\" ...", vim.log.levels.INFO)
    require("ms-teams.graph").search_chat_messages(chat_id, q, function(res, err)
      vim.schedule(function()
        if err then vim.notify("search failed: " .. tostring(err), vim.log.levels.ERROR); return end
        if not res or #res == 0 then vim.notify("no matches for \"" .. q .. "\"", vim.log.levels.INFO); return end
        local ok_t, telescope = pcall(require, "telescope")
        if not ok_t then vim.notify("telescope not available", vim.log.levels.ERROR); return end
        local pickers = require("telescope.pickers")
        local finders = require("telescope.finders")
        local conf = require("telescope.config").values
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")
        local items = {}
        for _, m in ipairs(res) do
          if m ~= vim.NIL then
            local plain = extract_message_plain(m)
            local snippet, _, _ = make_snippet(plain, q)
            local from = nv(m.from) and nv(m.from.user) and nv(m.from.user.displayName) or "unknown"
            local dt = format_date(nv(m.createdDateTime) or "")
            table.insert(items, { msg = m, display = from .. " (" .. dt .. "): " .. snippet, plain = plain })
          end
        end
        pickers.new({}, {
          prompt_title = "Search \"" .. q .. "\" in " .. (format_chat(chat) or chat_id),
          finder = finders.new_table({ results = items, entry_maker = function(e) return { value = e.msg, display = e.display, ordinal = e.plain } end }),
          sorter = conf.generic_sorter({}),
          attach_mappings = function(pb, map)
            actions.select_default:replace(function()
              actions.close(pb)
              local sel = action_state.get_selected_entry()
              if sel and sel.value then
                local target_id = nv(sel.value.id)
                if target_id then ensure_message_and_jump(chat, detail_buf, target_id, q) end
              end
            end)
            local function entry_msg(e)
              if type(e) ~= "table" then return nil end
              local m = e.value
              if type(m) == "table" and m ~= vim.NIL and nv(m.id) then return m end
              if nv(e.id) then return e end
              return nil
            end
            local function send_qf(msgs)
              send_msgs_to_qflist(chat, detail_buf, msgs, q)
            end
            local function map_qf(mode, lhs, get_list)
              map(mode, lhs, function(pb2)
                local picker = action_state.get_current_picker(pb2)
                local list = get_list(picker) or {}
                actions.close(pb2)
                local msgs = {}
                for _, e in ipairs(list) do
                  local m = entry_msg(e)
                  if m then table.insert(msgs, m) end
                end
                if #msgs == 0 then
                  -- fallback: full (unfiltered) result set
                  for _, it in ipairs(items) do if it.msg then table.insert(msgs, it.msg) end end
                end
                send_qf(msgs)
              end)
            end
            local function all_entries(picker)
              local out = {}
              if picker and picker.manager and picker.manager.iter then
                for entry in picker.manager:iter() do table.insert(out, entry) end
              end
              return out
            end
            local function selected_entries(picker)
              local sel = picker and picker.get_multi_selection and picker:get_multi_selection() or {}
              if #sel > 0 then return sel end
              local cur = action_state.get_selected_entry()
              if cur then return { cur } end
              return {}
            end
            map_qf("i", "<C-q>", all_entries)
            map_qf("n", "<C-q>", all_entries)
            map_qf("i", "<M-q>", selected_entries)
            map_qf("n", "<M-q>", selected_entries)
            return true
          end,
        }):find()
      end)
    end, team_id)
  end)
end

function M.show_messages(chat, open)
  open = open or "split"
  local chat_id = nv(chat.id)
  if not chat_id then
    vim.notify("chat has no id (vim.NIL)", vim.log.levels.ERROR)
    return
  end
  local is_channel = nv(chat.chatType) == "channel" and nv(chat.teamId) ~= nil
  local team_id = nv(chat.teamId)
  local cache = require("ms-teams.cache")
  local safe_id_cache = chat_id:gsub("[^%w%-_:.]", "_"):sub(1, 60)
  local cache_key = "messages_" .. safe_id_cache
  -- channels carry no server viewpoint: infer read position from previously
  -- cached messages (transient, per open) so detail highlights match chats
  if is_channel and not cache.get_last_read(chat_id) then
    local seen_newest = channel_seen_newest(chat_id)
    if seen_newest then
      chat.viewpoint = { lastMessageReadDateTime = seen_newest }
    end
  end
  local CACHE_TTL = 45
  local function do_list_messages(id, cb, nextLink)
    if is_channel then
      require("ms-teams.graph").list_channel_messages(team_id, id, cb, nextLink)
    else
      require("ms-teams.graph").list_messages(id, cb, nextLink)
    end
  end
  local function do_list_until_read(id, last_iso, cb)
    if is_channel then
      require("ms-teams.graph").list_channel_messages_until_read(team_id, id, last_iso, cb)
    else
      require("ms-teams.graph").list_messages_until_read(id, last_iso, cb)
    end
  end

  local function render_buffer(msgs, nextLink, opts)
    opts = opts or {}
    -- coalesce background re-renders (tab resolve, search jump, watch) — they
    -- fire in bursts and each full set_lines flickers the cursor
    if opts.no_cursor and opts.buf and vim.api.nvim_buf_is_valid(opts.buf) and not opts.force then
      local b = opts.buf
      if pending_detail_renders[b] then
        pending_detail_renders[b] = { msgs = msgs, nextLink = nextLink, opts = vim.deepcopy(opts) }
        return b
      end
      pending_detail_renders[b] = { msgs = msgs, nextLink = nextLink, opts = vim.deepcopy(opts) }
      vim.defer_fn(function()
        local p = pending_detail_renders[b]
        pending_detail_renders[b] = nil
        if p and vim.api.nvim_buf_is_valid(b) then
          p.opts.force = true
          -- keep same buf identity; bypass coalesce on this final flush
          render_buffer(p.msgs, p.nextLink, p.opts)
        end
      end, 35)
      return opts.buf
    end
    local is_cached = opts.is_cached
    if not msgs then msgs = {} end
    local buf = opts.buf
    local reuse = buf and vim.api.nvim_buf_is_valid(buf)
    if not reuse then
      -- reuse an existing buffer for this chat when present: creating a new
      -- one every time leaves timestamp-suffixed duplicates whose
      -- id_to_lnum maps desync the <CR>-jump scans
      local want = "__" .. safe_id_cache
      local displayed, hidden_list = nil, {}
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) then
          local n = vim.api.nvim_buf_get_name(b)
          if n:find("ms-teams://chat", 1, true) and n:find(want, 1, true) then
            if vim.fn.bufwinid(b) ~= -1 and not displayed then displayed = b
            else table.insert(hidden_list, b) end
          end
        end
      end
      if displayed then
        buf = displayed
      elseif #hidden_list > 0 then
        table.sort(hidden_list, function(a, c) return a > c end)
        buf = hidden_list[1]
      end
      if buf then
        -- drop remaining duplicates so future scans converge on one buffer
        for _, b in ipairs(hidden_list) do
          if b ~= buf then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
        end
      else
        buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
      end
    end
    local title = format_chat(chat) or nv(chat.topic) or nv(chat.chatType) or chat_id
    local safe_id = safe_id_cache
    local chat_name = title
    local safe_name = to_ascii(chat_name):gsub("[^%w%-_ %.]", "_"):gsub("%s+", "-"):sub(1, 40)
    set_listed_scratch(buf, "ms-teams://chat/" .. safe_name .. "__" .. safe_id)
    local HEADER_LINES = 6
    local header_suffix = is_cached and " (cached)" or ""
    local lines = { "# " .. chat_name, "", string.format("Chat: %s | %d messages%s", chat_id, #msgs, header_suffix), "", "Press g? participants | S reply | R refresh | gR load 50 older | g/ search | gF telescope search | mr mark read | mu mark unread | q close | <CR> jump reply", "" }
    -- enrich header for oneOnOne with missing members (was oneOnOne)
    if nv(chat.chatType) == "oneOnOne" and chat_name:match("^oneOnOne") then
      require("ms-teams.graph").get_chat(chat_id, function(full)
        if full and full.members then
          chat.members = full.members
          local new_name = format_chat(chat)
          if new_name and not new_name:match("^oneOnOne") then
            vim.schedule(function()
              if vim.api.nvim_buf_is_valid(buf) then
                local cur = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
                if cur:match("^# oneOnOne") then
                  vim.api.nvim_buf_set_lines(buf, 0, 1, false, {"# " .. new_name})
                  pcall(vim.api.nvim_buf_set_name, buf, "ms-teams://chat/"..to_ascii(new_name):gsub("[^%w%-_ %.]","_"):gsub("%s+","-"):sub(1,40).."__"..safe_id)
                end
              end
            end)
          end
        end
      end)
    end
    local unread_msg_lines = {}
    local id_to_lnum = {}
    local reply_to_target = {}
    local image_map = {}
    local sorted_msgs = {}
    for _, m in ipairs(msgs) do
      if m ~= vim.NIL and m ~= nil then table.insert(sorted_msgs, m) end
    end
    table.sort(sorted_msgs, function(a,b)
      local at = nv(a.createdDateTime) or ""
      local bt = nv(b.createdDateTime) or ""
      return at < bt
    end)

    -- find last read message in sorted_msgs (the newest message where createdDateTime <= last_read_iso)
    local last_read_msg_idx = nil
    local last_read_iso = get_last_read_iso(chat)
    if last_read_iso and last_read_iso ~= "" then
      for i = #sorted_msgs, 1, -1 do
        local ct = nv(sorted_msgs[i].createdDateTime)
        if ct and ct <= last_read_iso then
          last_read_msg_idx = i
          break
        end
      end
    end

    -- find first unread message
    local first_unread_idx = nil
    for i = 1, #sorted_msgs do
      if is_message_unread(sorted_msgs[i], chat) then first_unread_idx = i; break end
    end

    local inserted_last_read = false
    for i = 1, #sorted_msgs do
      local cur = sorted_msgs[i]
      if cur ~= vim.NIL and cur ~= nil and not inserted_last_read and first_unread_idx and i == first_unread_idx then
        -- Prefer the date of the actual last read message if present, otherwise format last_read_iso
        local date_str = ""
        if last_read_msg_idx and sorted_msgs[last_read_msg_idx] then
          local lr_msg = sorted_msgs[last_read_msg_idx]
          local lr_dt = format_date(nv(lr_msg.createdDateTime) or "")
          date_str = lr_dt ~= "" and lr_dt or ""
        elseif last_read_iso and last_read_iso ~= "" then
          date_str = format_date(last_read_iso)
        end
        local divider = date_str ~= "" and ("---------- Last read " .. date_str .. " ---------------") or "---------- Last read ---------------"
        table.insert(lines, divider)
        inserted_last_read = true
      end
      local res = build_message_lines(cur, chat)
      if not res then goto continue end
      local header_lnum = #lines + 1
      if res.id then id_to_lnum[res.id] = header_lnum end
      if res.is_unread then unread_msg_lines[header_lnum] = true end
      for idx, l in ipairs(res.lines) do
        table.insert(lines, l)
        if res.reply_target and #lines == header_lnum + 1 and res.reply_preview then
          reply_to_target[#lines] = res.reply_target
        end
        if (l:find("%[Image:") or l:find("%[File:")) and res.img_srcs and #res.img_srcs > 0 then
          -- map this image line to its src (by order, nth image line -> nth src)
          local img_idx = 0
          for _, ll in ipairs(res.lines) do
            if ll:find("%[Image:") or ll:find("%[File:") then
              img_idx = img_idx + 1
              if ll == l then
                image_map[#lines] = res.img_srcs[img_idx]
                break
              end
            end
          end
        end
      end
      ::continue::
    end
    table.insert(lines, "---")
    table.insert(lines, "Chat: " .. format_chat(chat) .. " | " .. #msgs .. " messages")
    table.insert(lines, "Hints: q close | S reply (<C-p> paste img) | R refresh | g/ search | gF telescope search | g? participants | mr mark read | mu mark unread | gR load 50 older | <CR> jump to original")

    -- dirty check: skip full set_lines/highlights if content identical (major flicker source)
    local do_render = true
    if not opts.force and vim.api.nvim_buf_is_valid(buf) then
      local ok_old, old = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
      if ok_old and old and #old == #lines then
        local same = true
        for i = 1, #lines do if old[i] ~= lines[i] then same = false; break end end
        if same then do_render = false end
      end
    end
    local ns = vim.api.nvim_create_namespace("ms_teams_msg_unread")
    if do_render then
      -- preserve view for background re-renders (no_cursor)
      local win_for_view = vim.fn.bufwinid(buf)
      local saved_view = nil
      if win_for_view ~= -1 and (opts.no_cursor or opts.keep_cursor) then
        saved_view = vim.api.nvim_win_call(win_for_view, function() return vim.fn.winsaveview() end)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      if saved_view and win_for_view ~= -1 then
        pcall(vim.api.nvim_win_call, win_for_view, function() vim.fn.winrestview(saved_view) end)
      end
    end
    -- highlights always re-applied: unread state can change without text
    -- changes, and extmark updates don't move the cursor
    do
      local hl_group = get_unread_hl_group()
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      for lnum, _ in pairs(unread_msg_lines) do
        vim.api.nvim_buf_add_highlight(buf, ns, hl_group, lnum - 1, 0, eol_col(buf, lnum))
      end
    end
    -- keep ns var even when skipping render
    pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_ns", ns)

    vim.api.nvim_buf_set_var(buf, "ms_teams_chat_id", chat_id)
    vim.api.nvim_buf_set_var(buf, "ms_teams_chat", chat)
    vim.api.nvim_buf_set_var(buf, "ms_teams_raw_msgs", msgs)
    vim.api.nvim_buf_set_var(buf, "ms_teams_id_to_lnum", id_to_lnum)
    vim.api.nvim_buf_set_var(buf, "ms_teams_reply_map", reply_to_target)
    vim.api.nvim_buf_set_var(buf, "ms_teams_image_map", image_map)
    vim.api.nvim_buf_set_var(buf, "ms_teams_unread_lines", unread_msg_lines)
    vim.api.nvim_buf_set_var(buf, "ms_teams_nextLink", nextLink or "")
    vim.api.nvim_buf_set_var(buf, "ms_teams_total", #msgs)
    vim.api.nvim_buf_set_var(buf, "ms_teams_ns", ns)
    vim.api.nvim_buf_set_var(buf, "ms_teams_cache_key", cache_key)
    -- expose silent re-render for jump flows (same buffer, no window changes)
    pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_detail_render", function(m, nl, o)
      o = o or {}
      o.buf = buf
      o.no_open = true
      return render_buffer(m, nl, o)
    end)
    -- resolve tabReference attachments (e.g. Excel added as tab): fetch chat
    -- tabs once, patch contentUrl on the message objects, re-render silently
    do
      local pending = {}
      for _, m in ipairs(msgs) do
        if m ~= vim.NIL and m ~= nil then
          local matts = nv(m.attachments)
          if matts and type(matts) == "table" then
            for _, a in ipairs(matts) do
              if a ~= vim.NIL and nv(a.contentType) == "tabReference" and not a._tab_failed and not a._tab_direct then
                local existing = nv(a.contentUrl) or ""
                -- stable sharing links (/:x:/) are reused as-is; direct URLs
                -- may be stale (cached) so they are always re-resolved
                if not existing:find("/:[a-z]:/") then
                  local tid, tname = parse_tab_reference(nv(a.content) or "")
                  local mname = fully_decode(nv(a.name) or "")
                  if mname == "" and tname then mname = fully_decode(tname) end
                  if tid or mname ~= "" then
                    table.insert(pending, { att = a, tab_id = tid, match_name = mname ~= "" and mname or nil })
                  end
                end
              end
            end
          end
        end
      end
      if #pending > 0 and os.time() >= tab_throttle_until then
        require("ms-teams.graph").list_chat_tabs(chat_id, function(tabs, terr)
          if not tabs then
            for _, p in ipairs(pending) do p.att._tab_failed = true end
            if tostring(terr):find("TooManyRequests") then
              tab_throttle_until = os.time() + 300
              vim.notify("ms-teams: tab resolve throttled, paused 5m", vim.log.levels.WARN)
            else
              vim.notify("ms-teams: tab file resolve failed: " .. tostring(terr), vim.log.levels.ERROR)
            end
            return
          end
          local by_id = {}
          if type(tabs) == "table" then
            for _, t in ipairs(tabs) do
              if t ~= vim.NIL and nv(t.id) then by_id[nv(t.id)] = t end
            end
          end
          local changed = false
          local link_pending = {}
          for _, p in ipairs(pending) do
            local t = p.tab_id and by_id[p.tab_id] or nil
            if not t and p.match_name then
              local want = p.match_name:lower()
              for _, cand in pairs(by_id) do
                local dn = nv(cand.displayName) or ""
                if dn == p.match_name or dn:lower() == want then t = cand; break end
              end
            end
            p.tab = t
            if t then
              local cfg = nv(t.configuration) or {}
              local did, docid = parse_drive_ids(nv(cfg.websiteUrl) or "")
              if did and docid then
                p.drive_id, p.doc_id = did, docid
                table.insert(link_pending, p)
              else
                local url = unwrap_tab_url(nv(cfg.contentUrl) or nv(cfg.websiteUrl) or "")
                if url ~= "" then
                  if p.att.contentUrl ~= url then p.att.contentUrl = url; changed = true end
                  if (nv(p.att.name) or "") == "" then
                    local nn = nv(t.displayName) or p.match_name or "tab file"
                    if nn ~= "" then p.att.name = nn; changed = true end
                  end
                  p.att._tab_direct = true
                else
                  p.att._tab_failed = true
                end
              end
            else
              p.att._tab_failed = true
            end
          end
          local function finish_tabs()
            if changed then
              vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(buf) then return end
                local win = vim.fn.bufwinid(buf)
                local cur = win ~= -1 and vim.api.nvim_win_get_cursor(win) or nil
                -- TEMPDEBUG cursor trace
                pcall(vim.fn.writefile, { string.format("%s finish_tabs render buf=%d cur=%s", os.date("%H:%M:%S"), buf, cur and cur[1] or "nil(hidden)") }, "/tmp/ms_cursor.log", "a")
                render_buffer(msgs, nextLink, { buf = buf, keep_cursor = true, no_open = true, is_cached = opts.is_cached, target_cursor = cur and cur[1] or nil })
              end)
            else
              vim.notify("ms-teams: could not resolve tab file (tab not found or no contentUrl)", vim.log.levels.WARN)
            end
          end
          if #link_pending == 0 then finish_tabs(); return end
          local remaining = #link_pending
          for _, p in ipairs(link_pending) do
            graph.create_sharing_link(p.drive_id, p.doc_id, function(link_url, lerr)
              if link_url and link_url ~= "" then
                if p.att.contentUrl ~= link_url then p.att.contentUrl = link_url; changed = true end
                if (nv(p.att.name) or "") == "" then
                  local nn = (p.tab and nv(p.tab.displayName)) or p.match_name or "tab file"
                  if nn ~= "" then p.att.name = nn; changed = true end
                end
              else
                -- fallback to direct file URL (may need interactive login)
                local cfg = (p.tab and nv(p.tab.configuration)) or {}
                local url = unwrap_tab_url(nv(cfg.contentUrl) or nv(cfg.websiteUrl) or "")
                if url ~= "" then
                  if p.att.contentUrl ~= url then p.att.contentUrl = url; changed = true end
                  if (nv(p.att.name) or "") == "" then
                    local nn = (p.tab and nv(p.tab.displayName)) or p.match_name or "tab file"
                    if nn ~= "" then p.att.name = nn; changed = true end
                  end
                  p.att._tab_direct = true
                else
                  p.att._tab_failed = true
                end
              end
              remaining = remaining - 1
              if remaining == 0 then finish_tabs() end
            end)
          end
        end)
      end
    end
    if not opts.no_open then
      if open == "current" then
        vim.api.nvim_win_set_buf(0, buf)
      elseif open == "vsplit" then
        vim.cmd("vsplit")
        vim.api.nvim_win_set_buf(0, buf)
      else
        vim.cmd("split")
        vim.api.nvim_win_set_buf(0, buf)
      end

    end
    local first_unread = nil
    for lnum, _ in pairs(unread_msg_lines) do
      if not first_unread or lnum < first_unread then first_unread = lnum end
    end
    local target = opts.target_cursor or (opts.keep_cursor and nil) or first_unread or #lines
    -- no_cursor: background re-render for jump flows must not move any cursor
    if target and not opts.no_cursor then
      -- TEMPDEBUG cursor trace
      local dbg_from = opts.target_cursor and "explicit" or (first_unread and "first_unread" or "END(#lines)")
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(buf) then
          local win = vim.fn.bufwinid(buf)
          if win ~= -1 then
            -- clamp: re-fetch may return fewer lines (first page) than the
            -- saved cursor; unclamped set_cursor fails and nvim drops to bottom
            local lc = vim.api.nvim_buf_line_count(buf)
            target = math.max(1, math.min(target, lc))
            pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
            pcall(vim.fn.writefile, { string.format("%s render-cursor buf=%d target=%d/%d from=%s nc=%s", os.date("%H:%M:%S"), buf, target, lc, dbg_from, tostring(opts.no_cursor)) }, "/tmp/ms_cursor.log", "a")
          end
        end
      end, 10)
    end

    local loading = false
    local function do_load_older()
      if loading then vim.notify("already loading...", vim.log.levels.INFO); return end
      local nl = ""
      local ok, v = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_nextLink")
      if ok then nl = v or "" end
      if not nl or nl == "" then
        vim.notify("no more messages (top reached)", vim.log.levels.INFO)
        return
      end
      local win_before = vim.fn.bufwinid(buf)
      local view_before = nil
      local lnum_before = nil
      local col_before = 0
      local target_id_before = nil
      local target_lnum_before = nil
      if win_before ~= -1 then
        view_before = vim.api.nvim_win_call(win_before, function() return vim.fn.winsaveview() end)
        local cur = vim.api.nvim_win_get_cursor(win_before)
        lnum_before = cur[1]
        col_before = cur[2]
        -- find message id under cursor (nearest header <= lnum)
        local ok_map, id_map = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_id_to_lnum")
        if ok_map and type(id_map) == "table" and lnum_before then
          local best_lnum = -1
          for id, lnum in pairs(id_map) do
            if lnum <= lnum_before and lnum > best_lnum then
              best_lnum = lnum
              target_id_before = id
              target_lnum_before = lnum
            end
          end
          if not target_id_before then
            local min_lnum = math.huge
            for id, lnum in pairs(id_map) do
              if lnum < min_lnum then min_lnum = lnum; target_id_before = id; target_lnum_before = lnum end
            end
          end
        end
      end
      loading = true
      vim.notify("loading 50 older messages...", vim.log.levels.INFO)
      -- virtual progress (no real line insertion → no flicker/layout shift)
      pcall(vim.api.nvim_buf_clear_namespace, buf, detail_loading_ns, 0, -1)
      pcall(vim.api.nvim_buf_set_extmark, buf, detail_loading_ns, HEADER_LINES - 1, 0, { virt_text = { { "⟳ Loading 50 more…", "Comment" } }, virt_text_pos = "eol", hl_mode = "combine" })
      do_list_messages(chat_id, function(more, err2, next2)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buf) then loading=false; return end
          pcall(vim.api.nvim_buf_clear_namespace, buf, detail_loading_ns, 0, -1)
          if err2 then
            vim.notify("load more failed: "..err2, vim.log.levels.ERROR)
            loading=false; return
          end
          if not more or #more==0 then
            vim.notify("no more messages", vim.log.levels.INFO)
            pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_nextLink", next2 or "")
            loading=false; return
          end
           local tmp_lines = {}
           local new_id_to_lnum = {}
           local new_reply_map = {}
           local new_unread = {}
           local new_image_map = {}
           for i = #more, 1, -1 do
             local res = build_message_lines(more[i], chat)
             if not res then goto cont2 end
             local h_lnum_in_block = #tmp_lines + 1
             if res.id then new_id_to_lnum[res.id] = HEADER_LINES + h_lnum_in_block end
             if res.is_unread then new_unread[HEADER_LINES + h_lnum_in_block] = true end
             for idx, l in ipairs(res.lines) do
               table.insert(tmp_lines, l)
               local abs_lnum = HEADER_LINES + h_lnum_in_block + idx -1
               if res.reply_target and idx == 2 and res.reply_preview then
                 new_reply_map[abs_lnum] = res.reply_target
               end
                if (l:find("%[Image:") or l:find("%[File:")) and res.img_srcs and #res.img_srcs > 0 then
                  -- map this image line to its src (nth image)
                  local img_idx = 0
                  for _, ll in ipairs(res.lines) do
                    if ll:find("%[Image:") or ll:find("%[File:") then
                      img_idx = img_idx + 1
                      if ll == l then
                        new_image_map[abs_lnum] = res.img_srcs[img_idx]
                        break
                      end
                    end
                  end
                end
             end
             ::cont2::
           end
          local inserted = #tmp_lines
          if inserted == 0 then
            vim.notify("no renderable older messages", vim.log.levels.WARN)
            pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_nextLink", next2 or "")
            loading=false; return
          end
          local cur_msgs = {}
          pcall(function() cur_msgs = vim.api.nvim_buf_get_var(buf, "ms_teams_raw_msgs") or {} end)
          local combined = {}
          for _, m in ipairs(cur_msgs) do table.insert(combined, m) end
          for _, m in ipairs(more) do table.insert(combined, m) end
          pcall(vim.api.nvim_buf_set_var, buf, "ms_teams_raw_msgs", combined)
          cache.save(cache_key, { messages = combined, nextLink = next2 or "" })

           -- Re-render entire buffer with all accumulated messages so sorting & Last read divider are 100% consistent
            render_buffer(combined, next2, { is_cached = false, buf = buf, no_open = true, no_cursor = true, force = true })

            local win = vim.fn.bufwinid(buf)
            if win ~= -1 and target_id_before then
              local ok_new, new_map = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_id_to_lnum")
              local new_lnum = ok_new and new_map and new_map[target_id_before] or nil
              if new_lnum then
                local offset = 0
                if lnum_before and target_lnum_before then offset = lnum_before - target_lnum_before end
                local cur_keep = new_lnum + offset
                if view_before then
                  local delta = new_lnum - (target_lnum_before or lnum_before or new_lnum)
                  view_before.topline = view_before.topline + delta
                  view_before.lnum = cur_keep
                  view_before.col = col_before
                  view_before.lnum_add = 0
                  pcall(vim.api.nvim_win_call, win, function() vim.fn.winrestview(view_before) end)
                end
                pcall(vim.api.nvim_win_set_cursor, win, { cur_keep, col_before })
              elseif view_before and lnum_before then
                -- fallback: line offset
                local cur_keep2 = lnum_before + inserted
                view_before.lnum = cur_keep2
                pcall(vim.api.nvim_win_call, win, function() vim.fn.winrestview(view_before) end)
                pcall(vim.api.nvim_win_set_cursor, win, { cur_keep2, col_before })
              end
            elseif win ~= -1 and lnum_before then
              local cur_keep2 = lnum_before + inserted
              if view_before then
                view_before.lnum = cur_keep2
                pcall(vim.api.nvim_win_call, win, function() vim.fn.winrestview(view_before) end)
              end
              pcall(vim.api.nvim_win_set_cursor, win, { cur_keep2, col_before })
            end
            vim.notify(string.format("50 more messages loaded (%d total)%s", #combined, (next2 and next2~="" and "" or " - all loaded")), vim.log.levels.INFO)
          loading = false
        end)
      end, nl)
    end

    -- compose split dedicado (opción 1): S abre buffer editable con todos tus atajos, <C-s> envía
    local compose_buf = nil
    local function send_compose()
      if not compose_buf or not vim.api.nvim_buf_is_valid(compose_buf) then
        vim.notify("no compose buffer", vim.log.levels.WARN); return
      end
      local lines = vim.api.nvim_buf_get_lines(compose_buf, 0, -1, false)
      local text = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if text == "" then vim.notify("compose empty", vim.log.levels.WARN); return end
      vim.api.nvim_buf_set_option(compose_buf, "modifiable", false)
      graph.send_message(chat_id, text, function(_, err)
        vim.schedule(function()
          if compose_buf and vim.api.nvim_buf_is_valid(compose_buf) then
            vim.api.nvim_buf_set_option(compose_buf, "modifiable", true)
          end
          if err then vim.notify("send failed: " .. err, vim.log.levels.ERROR); return end
          vim.notify("sent", vim.log.levels.INFO)
          -- close compose window and wipe buffer
          if compose_buf and vim.api.nvim_buf_is_valid(compose_buf) then
            local win = vim.fn.bufwinid(compose_buf)
            if win ~= -1 then
              pcall(vim.api.nvim_win_close, win, true)
            end
            pcall(vim.api.nvim_buf_delete, compose_buf, { force = true })
            compose_buf = nil
          end
          local safe = chat_id:gsub("[^%w%-_:.]", "_"):sub(1, 60)
          pcall(vim.fn.delete, vim.fn.stdpath("cache") .. "/ms-teams/messages_" .. safe .. ".json")
          do_list_messages(chat_id, function(fresh, err2, freshNext)
            if err2 or not fresh then return end
            vim.schedule(function()
              if not vim.api.nvim_buf_is_valid(buf) then return end
              cache.save(cache_key, { messages = fresh, nextLink = freshNext or "" })
              render_buffer(fresh, freshNext, { is_cached = false, buf = buf, no_open = true })
            end)
          end)
        end)
      end)
    end
    local function paste_image_to_compose()
      if not compose_buf or not vim.api.nvim_buf_is_valid(compose_buf) then return end
      local attach_dir = vim.fn.stdpath("cache") .. "/ms-teams/attachments"
      vim.fn.mkdir(attach_dir, "p")
      local filename = "image_" .. os.date("%Y%m%d_%H%M%S") .. ".png"
      local filepath = attach_dir .. "/" .. filename

      -- 1. Try pngpaste (fastest on macOS)
      local out = vim.fn.system({ "pngpaste", filepath })
      local ok_save = (vim.v.shell_error == 0 and vim.fn.filereadable(filepath) == 1 and vim.fn.getfsize(filepath) > 100)

      -- 2. Fallback to osascript on macOS if pngpaste failed
      if not ok_save then
        local apple_script = string.format([[
          set targetPath to POSIX file "%s"
          try
            set theImage to the clipboard as «class PNGf»
            set theFile to open for access targetPath with write permission
            set eof theFile to 0
            write theImage to theFile
            close access theFile
            return "OK"
          on error
            try
              close access targetPath
            end try
            return "ERROR"
          end try
        ]], filepath)
        local osa_out = vim.fn.system({ "osascript", "-e", apple_script })
        ok_save = (vim.v.shell_error == 0 and osa_out:find("OK") and vim.fn.filereadable(filepath) == 1 and vim.fn.getfsize(filepath) > 100)
      end

      if not ok_save then
        vim.notify("No valid PNG image found in system clipboard (copy an image first)", vim.log.levels.WARN)
        return
      end

      local image_markdown = string.format("![image](%s)", filepath)
      local cur_win = vim.fn.bufwinid(compose_buf)
      local cur_pos = cur_win ~= -1 and vim.api.nvim_win_get_cursor(cur_win) or { 1, 0 }
      local row = cur_pos[1]
      local cur_line = vim.api.nvim_buf_get_lines(compose_buf, row - 1, row, false)[1] or ""

      if cur_line == "" then
        vim.api.nvim_buf_set_lines(compose_buf, row - 1, row, false, { image_markdown })
      else
        vim.api.nvim_buf_set_lines(compose_buf, row, row, false, { image_markdown })
        if cur_win ~= -1 then
          pcall(vim.api.nvim_win_set_cursor, cur_win, { row + 1, 0 })
        end
      end
      vim.notify("Pasted image from clipboard: " .. filename, vim.log.levels.INFO)
    end

    local function open_compose()
      local cname = "ms-teams://compose/" .. safe_id_cache
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == cname then compose_buf = b; break end
      end
      if not compose_buf or not vim.api.nvim_buf_is_valid(compose_buf) then
        compose_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(compose_buf, cname)
        vim.api.nvim_buf_set_option(compose_buf, "buftype", "acwrite")
        vim.api.nvim_buf_set_option(compose_buf, "bufhidden", "hide")
        vim.api.nvim_buf_set_option(compose_buf, "swapfile", false)
        vim.api.nvim_buf_set_option(compose_buf, "filetype", "markdown")
        vim.api.nvim_buf_set_var(compose_buf, "ms_teams_compose_chat_id", chat_id)
        vim.keymap.set({ "n", "i" }, "<C-s>", send_compose, { buffer = compose_buf, desc = "Teams send compose" })
        vim.keymap.set({ "n", "i" }, "<C-p>", paste_image_to_compose, { buffer = compose_buf, desc = "Teams paste clipboard image" })
        vim.keymap.set("n", "q", function() vim.api.nvim_buf_delete(compose_buf, { force = true }) end, { buffer = compose_buf, desc = "Close compose" })
        vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = compose_buf, callback = send_compose })
        vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { "" })
      end
      local chat_win = vim.fn.bufwinid(buf)
      if chat_win ~= -1 then vim.api.nvim_set_current_win(chat_win) end
      vim.cmd("belowright 7split")
      vim.api.nvim_win_set_buf(0, compose_buf)
    end
    vim.keymap.set("n", "S", open_compose, { buffer = buf, desc = "Teams compose reply" })
    vim.keymap.set("n", "q", function() vim.api.nvim_buf_delete(buf, { force = true }) end, { buffer = buf })
    vim.keymap.set("n", "g?", function() M.show_participants(chat) end, { buffer = buf, desc = "Teams participants" })
    vim.keymap.set("n", "g/", function() M.search_in_chat(chat, buf) end, { buffer = buf, desc = "Search in chat (buffer)" })
    vim.keymap.set("n", "gF", function() M.search_in_chat_telescope(chat, buf) end, { buffer = buf, desc = "Search in chat (telescope)" })
    vim.keymap.set("n", "gx", function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local line = vim.api.nvim_get_current_line()
      if not (line:find("%[Image:") or line:find("%[File:")) then
        -- Default gx fallback: open URL / file under cursor
        local cfile = vim.fn.expand("<cfile>")
        if cfile and cfile ~= "" then
          if vim.ui and vim.ui.open then
            vim.ui.open(cfile)
          else
            vim.cmd("normal! gx")
          end
        else
          vim.cmd("normal! gx")
        end
        return
      end
      local ok, img_map = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_image_map")
      local src = nil
      if ok and img_map and img_map[lnum] then
        src = unwrap_tab_url(img_map[lnum])
      else
        vim.notify("image src not found, try reopening chat", vim.log.levels.WARN)
        return
      end
      -- SharePoint files (personal docs) need browser, not Bearer token (aud mismatch)
      -- ?web=1 opens in Office for the web (editable, collaborative) instead of downloading
      if src:find("sharepoint%.com") then
        -- match Teams' own link shape: fully single-encoded ASCII (spaces AND
        -- non-ASCII bytes encoded; existing %XX triplets untouched) so nothing
        -- downstream treats raw UTF-8 as unencoded text and re-encodes it
        local web_src = src:gsub(" ", "%%20")
        web_src = web_src:gsub("[\128-\255]", function(c) return string.format("%%%02X", string.byte(c)) end)
        if not web_src:find("[?&]web=") then
          web_src = web_src .. (web_src:find("?", 1, true) and "&web=1" or "?web=1")
        end
        pcall(vim.fn.setreg, "+", web_src)
        vim.notify("opening SharePoint file in browser (URL yanked to + register): " .. web_src, vim.log.levels.INFO)
        local open_cmd = require("ms-teams.config").options.open_cmd
        if open_cmd and type(open_cmd) == "table" and #open_cmd > 0 then
          local cmd = {}
          for _, v in ipairs(open_cmd) do table.insert(cmd, v) end
          table.insert(cmd, web_src)
          vim.fn.jobstart(cmd, { detach = true })
        elseif vim.ui and vim.ui.open then vim.ui.open(web_src) else vim.fn.jobstart({"open", web_src}, {detach=true}) end
        return
      end
      vim.notify("downloading image... src="..src:sub(1,120), vim.log.levels.DEBUG)
      local token = require("ms-teams.auth").get_token("read")
      if not token then vim.notify("no token", vim.log.levels.ERROR); return end
      local tmp = vim.fn.tempname() .. ".png"
      local tmp_hdrs = vim.fn.tempname()
      local out = vim.fn.system({"curl","-sL","--max-time","30","-D",tmp_hdrs,"-H","Authorization: Bearer "..token, src, "-o", tmp, "-w","\n%{http_code}"})
      local sz = vim.fn.getfsize(tmp)
      local hdrs = vim.fn.readfile(tmp_hdrs)
      local code = out:match("(%d%d%d)%s*$") or "000"
      pcall(vim.fn.delete, tmp_hdrs)
      if vim.v.shell_error ~= 0 or sz < 100 or code ~= "200" then
        local err = (out ~= "" and out or "") .. " http:"..code.." hdrs:"..table.concat(hdrs or {}, " "):sub(1,200).." src:"..src:sub(1,120)
        vim.notify("download failed: " .. err, vim.log.levels.ERROR)
        pcall(vim.fn.delete, tmp)
        -- fallback: open in browser
        if vim.ui and vim.ui.open then vim.ui.open(src) else vim.fn.jobstart({"open", src}, {detach=true}) end
        return
      end
      vim.notify("opening with Preview...", vim.log.levels.INFO)
      vim.fn.jobstart({"open", tmp}, {detach=true})
    end, { buffer = buf, desc = "Open image or default gx" })
    -- anchor helpers: position survives Last-read divider insert/remove
    -- across re-renders (raw lnum goes stale when divider appears/vanishes)
    local function anchor_at(lnum)
      local okm, id_map = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_id_to_lnum")
      if not (okm and id_map) then return nil, 0 end
      local best_id, best_lnum = nil, -1
      for id, hlnum in pairs(id_map) do
        if type(hlnum) == "number" and hlnum <= lnum and hlnum > best_lnum then
          best_lnum, best_id = hlnum, id
        end
      end
      if not best_id then return nil, 0 end
      return best_id, lnum - best_lnum
    end
    local function rerender_at_anchor(msgs, nextLink, anchor_id, anchor_off, fallback_lnum, fallback_col)
      render_buffer(msgs, nextLink, { is_cached = false, buf = buf, no_open = true, no_cursor = true, force = true })
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local win = vim.fn.bufwinid(buf)
      if win == -1 then return end
      local lc = vim.api.nvim_buf_line_count(buf)
      local nl = nil
      if anchor_id then
        local okm, new_map = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_id_to_lnum")
        if okm and new_map and new_map[anchor_id] then
          nl = math.max(1, math.min(new_map[anchor_id] + (anchor_off or 0), lc))
        end
      end
      nl = nl or (fallback_lnum and math.max(1, math.min(fallback_lnum, lc)) or nil)
      if nl then pcall(vim.api.nvim_win_set_cursor, win, { nl, fallback_col or 0 }) end
    end
    vim.keymap.set("n", "mr", function()
      local cur_pos = vim.api.nvim_win_get_cursor(0)
      -- guard against stale closures (reused buffers): act only if this
      -- buffer still shows the chat this mapping was created for
      do
        local ok_cur, cur_cid = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_chat_id")
        if ok_cur and cur_cid and cur_cid ~= chat_id then
          vim.notify("ms-teams: buffer chat changed, reopen the chat and retry", vim.log.levels.WARN)
          return
        end
      end
      local anchor_id, anchor_off = anchor_at(cur_pos[1])
      vim.ui.input({ prompt = string.format("Mark whole chat '%s' as read? (Y/n) [<CR>=y]: ", format_chat(chat)) }, function(ans)
        if ans and (ans:lower() == "n" or ans:lower() == "no") then vim.notify("cancelled", vim.log.levels.INFO); return end
        if not ans then vim.notify("cancelled", vim.log.levels.INFO); return end
        require("ms-teams.graph").mark_chat_read(chat_id, function(_, err)
          if err then
            vim.notify("mark_chat_read remote failed: " .. tostring(err), vim.log.levels.WARN)
          end
          local function do_local()
            local now_iso = os.date("!%Y-%m-%dT%H:%M:%SZ")
            require("ms-teams.cache").set_last_read(chat_id, now_iso)
            chat.viewpoint = chat.viewpoint or {}
            if chat.viewpoint == vim.NIL then chat.viewpoint = {} end
            chat.viewpoint.lastMessageReadDateTime = now_iso
            -- Immediately update highlight on existing chats list buffer
            M.update_chat_list_unread_state(chat_id, false)
            vim.schedule(function()
              if vim.api.nvim_buf_is_valid(buf) then
                local ns = vim.b[buf].ms_teams_ns or vim.api.nvim_create_namespace("ms_teams_msg_unread")
                vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
                -- auto re-render detail to remove Last read divider and highlights
                vim.defer_fn(function()
                  if vim.api.nvim_buf_is_valid(buf) then
                    -- re-render current chat detail with new lastRead
                    -- we have msgs and nextLink in closure, just re-render via cache
                    local ok, cur_msgs = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_msgs_cache")
                    -- fallback: re-fetch via Graph and re-render
                    do_list_messages(chat_id, function(fresh, err2, freshNext)
                      if err2 or not fresh then return end
                      vim.schedule(function()
                        if vim.api.nvim_buf_is_valid(buf) then
                          local cache_key2 = "messages_" .. safe_id_cache
                          require("ms-teams.cache").save(cache_key2, {messages=fresh, nextLink=freshNext or ""})
                          rerender_at_anchor(fresh, freshNext, anchor_id, anchor_off, cur_pos[1], cur_pos[2])
                        end
                      end)
                    end)
                  end
                end, 100)
              end
            end)
          end
          do_local()
        end)
      end)
    end, { buffer = buf, desc = "Mark chat read (whole chat)" })
    vim.keymap.set("n", "mu", function()
      local cur_pos = vim.api.nvim_win_get_cursor(0)
      do
        local ok_cur, cur_cid = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_chat_id")
        if ok_cur and cur_cid and cur_cid ~= chat_id then
          vim.notify("ms-teams: buffer chat changed, reopen the chat and retry", vim.log.levels.WARN)
          return
        end
      end
      local lnum = cur_pos[1]
      local anchor_id, anchor_off = anchor_at(lnum)
      local ok_map, id_to_lnum = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_id_to_lnum")
      local target_msg_id = nil
      local is_on_message = false
      if ok_map and id_to_lnum then
        -- only consider lines that are actually part of a message (header, reply, body), not footer ---/Chat:/Hints
        local cur_line = vim.api.nvim_get_current_line()
        -- footer lines start with --- or Chat: or Hints:
        if cur_line:match("^%-%-%-") or cur_line:match("^Chat:") or cur_line:match("^Hints:") or cur_line:match("^# ") then
          is_on_message = false
        else
          local headers = {}
          for mid, hlnum in pairs(id_to_lnum) do table.insert(headers, {mid=mid, lnum=hlnum}) end
          table.sort(headers, function(a,b) return a.lnum < b.lnum end)
          for i, h in ipairs(headers) do
            local next_lnum = headers[i+1] and headers[i+1].lnum or math.huge
            -- for last message, limit to not include footer (which starts after last message's body)
            -- footer starts at "---" line, which we can detect via content, but for now limit to next header or header+20 lines max
            -- simpler: if lnum is beyond last header + 20, consider it footer
            local max_end = h.lnum + 20
            local end_lnum = math.min(next_lnum, max_end)
            if lnum >= h.lnum and lnum < end_lnum then
              is_on_message = true
              target_msg_id = h.mid
              break
            end
          end
        end
      end
      if is_on_message and target_msg_id then
        vim.ui.input({ prompt = string.format("Mark message %s as unread? (Y/n) [<CR>=y]: ", target_msg_id:sub(1,8)) }, function(ans)
          if ans and (ans:lower() == "n" or ans:lower() == "no") then vim.notify("cancelled", vim.log.levels.INFO); return end
          if not ans then vim.notify("cancelled", vim.log.levels.INFO); return end
          local target_created = nil
          for _, m in ipairs(msgs) do
            if m ~= vim.NIL and nv(m.id) == target_msg_id then
              target_created = nv(m.createdDateTime)
              break
            end
          end
          if not target_created then vim.notify("cannot find message date", vim.log.levels.ERROR); return end
          local sub = vim.fn.system({"python3","-c","import datetime,sys; iso=sys.argv[1]; dt=datetime.datetime.fromisoformat(iso.replace('Z','+00:00')); print((dt - datetime.timedelta(seconds=1)).isoformat().replace('+00:00','Z'))", target_created}):gsub("%s+","")
          local new_last_read = sub ~= "" and sub or target_created
          require("ms-teams.cache").set_last_read(chat_id, new_last_read)
          chat.viewpoint = chat.viewpoint or {}
          if chat.viewpoint == vim.NIL then chat.viewpoint = {} end
          chat.viewpoint.lastMessageReadDateTime = new_last_read
          -- Immediately update highlight on existing chats list buffer
          M.update_chat_list_unread_state(chat_id, true)
          require("ms-teams.graph").mark_chat_unread(chat_id, new_last_read, function(_, err_graph)
            if err_graph then
              vim.notify("mark_chat_unread remote failed: " .. tostring(err_graph), vim.log.levels.WARN)
            end
            vim.defer_fn(function()
              if vim.api.nvim_buf_is_valid(buf) then
                do_list_messages(chat_id, function(fresh, err2, freshNext)
                  if err2 then return end
                  vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(buf) then
                      local cache_key2 = "messages_" .. safe_id_cache
                      require("ms-teams.cache").save(cache_key2, {messages=fresh, nextLink=freshNext or ""})
                      rerender_at_anchor(fresh, freshNext, anchor_id, anchor_off, cur_pos[1], cur_pos[2])
                    end
                  end)
                end)
              end
            end, 100)
          end)
        end)
      else
        vim.notify("marking as unread should be performed above a message (on **from** header, reply or body)", vim.log.levels.WARN)
      end
    end, { buffer = buf, desc = "Mark unread (on message only)" })
    vim.keymap.set("n", "gR", do_load_older, { buffer = buf, desc = "Teams load 50 older messages" })

    vim.keymap.set("n", "R", function()
      vim.notify("refreshing messages...", vim.log.levels.INFO)
      do_list_messages(chat_id, function(fresh, err, freshNext)
        if err then vim.notify("refresh failed: "..err, vim.log.levels.ERROR); return end
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buf) then return end
          cache.save(cache_key, {messages=fresh, nextLink=freshNext})
          -- re-render in same buffer without changing window layout
          render_buffer(fresh, freshNext, {is_cached=false, buf=buf, no_open=true})
          vim.notify(string.format("refreshed %d messages", #fresh), vim.log.levels.INFO)
        end)
      end)
    end, { buffer = buf, desc = "Teams refresh messages" })
    vim.keymap.set("n", "<CR>", function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local reply_map = vim.api.nvim_buf_get_var(buf, "ms_teams_reply_map")
      local id_map = vim.api.nvim_buf_get_var(buf, "ms_teams_id_to_lnum")
      local target_id = reply_map[lnum]
      if target_id and id_map[target_id] then
        vim.cmd("normal! m'")
        vim.cmd("normal! " .. id_map[target_id] .. "G")
        vim.notify("jumped to original: " .. target_id:sub(1,8) .. " (<C-o> to return)", vim.log.levels.INFO)
      elseif vim.api.nvim_get_current_line():match("^_↳ reply to:") then
        vim.notify("original message not in buffer (beyond 50 loaded - press R to load more)", vim.log.levels.WARN)
      end
    end, { buffer = buf, desc = "Jump to replied message" })
    -- :e refreshes in place instead of wiping the nofile buffer
    local e_grp = vim.api.nvim_create_augroup("MsTeamsChatDetail" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("BufReadCmd", { group = e_grp, buffer = buf, callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local cur = vim.api.nvim_win_get_cursor(0)[1]
      -- :e detaches treesitter synchronously before BufReadCmd fires; restore after re-render
      vim.notify("refreshing messages...", vim.log.levels.INFO)
      do_list_messages(chat_id, function(fresh, err, freshNext)
        if err then vim.notify("refresh failed: "..err, vim.log.levels.ERROR); return end
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buf) then return end
          cache.save(cache_key, {messages=fresh, nextLink=freshNext})
          render_buffer(fresh, freshNext, {is_cached=false, buf=buf, no_open=true, target_cursor=cur})
          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(buf) then pcall(vim.treesitter.start, buf) end
          end, 50)
          vim.notify(string.format("refreshed %d messages", #fresh), vim.log.levels.INFO)
        end)
      end)
    end })
  end

  -- try cache first (Teams-like instant open)
  local cached = cache.load(cache_key, CACHE_TTL)
  if cached and cached.messages and #cached.messages > 0 then
    render_buffer(cached.messages, cached.nextLink, {is_cached=true, open=open})
    -- stale-while-revalidate: background refresh without blocking UI
    vim.defer_fn(function()
      local last_read_iso = get_last_read_iso(chat)
      do_list_until_read(chat_id, last_read_iso, function(fresh, err, freshNext)
        if err or not fresh then return end
        local same = #fresh == #cached.messages and freshNext == cached.nextLink
        if same then
          for i=1, math.min(#fresh,3) do
            if fresh[i].id ~= cached.messages[i].id then same=false; break end
          end
        end
        if not same then
          cache.save(cache_key, {messages=fresh, nextLink=freshNext or ""})
          vim.schedule(function()
            local bufname = "ms-teams://chat/" .. safe_id_cache
            for _, b in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find(bufname,1,true) then
                vim.notify("Teams: chat actualizado ("..#fresh.." msgs) — pulsa R para refrescar", vim.log.levels.INFO)
                break
              end
            end
          end)
        end
      end)
    end, 150)
    return
  end

  -- cache miss: show loading then fetch
  local loading_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_option(loading_buf, "filetype", "markdown")
  local chat_name2 = format_chat(chat) or (nv(chat.topic) or nv(chat.chatType) or chat_id)
  local safe_name2 = to_ascii(chat_name2):gsub("[^%w%-_ %.]", "_"):gsub("%s+", "-"):sub(1, 40)
  set_listed_scratch(loading_buf, "ms-teams://chat/" .. safe_name2 .. "__" .. safe_id_cache)
  vim.api.nvim_buf_set_lines(loading_buf, 0, -1, false, {"# " .. (nv(chat.topic) or nv(chat.chatType) or chat_id), "", "Loading messages...", ""})
  if open == "current" then vim.api.nvim_win_set_buf(0, loading_buf)
  elseif open == "vsplit" then vim.cmd("vsplit"); vim.api.nvim_win_set_buf(0, loading_buf)
  else vim.cmd("split"); vim.api.nvim_win_set_buf(0, loading_buf) end
  local last_read_iso = get_last_read_iso(chat)
  do_list_until_read(chat_id, last_read_iso, function(msgs, err, nextLink)
    if err then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(loading_buf) then
          vim.api.nvim_buf_set_lines(loading_buf, 0, -1, false, {"# Error", "", err, ""})
        end
      end)
      return
    end
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(loading_buf) then pcall(vim.api.nvim_buf_delete, loading_buf, {force=true}) end
      render_buffer(msgs, nextLink, {is_cached=false, open=open})
      cache.save(cache_key, {messages=msgs, nextLink=nextLink or ""})
    end)
  end)
end


function M.show_participants(chat)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  set_listed_scratch(buf, "ms-teams://chat/" .. (nv(chat.id) or "unknown"):gsub("[^%w%-_:.]", "_"):sub(1, 50) .. "/participants")
  local title = "# Participants: " .. (nv(chat.topic) or nv(chat.chatType) or nv(chat.id) or "chat")
  local function render_members(members)
    local lines = { title, "" }
    if members and type(members) == "table" and #members > 0 then
      for _, m in ipairs(members) do
        if m == vim.NIL then goto cont end
        local name = nv(m.displayName) or "unknown"
        local email = nv(m.email) or ""
        local userId = nv(m.userId) or ""
        table.insert(lines, string.format("- %s%s%s", name, email ~= "" and " <" .. email .. ">" or "", userId ~= "" and " (" .. userId:sub(1, 8) .. ")" or ""))
        ::cont::
      end
    else
      table.insert(lines, "_no participants_")
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end
  end
  local members = nv(chat.members)
  if members and type(members) == "table" and #members > 0 then
    render_members(members)
  else
    -- fetch members on demand (group chats don't carry them in list_chats)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { title, "", "_Loading members..._" })
    local cid = nv(chat.id)
    require("ms-teams.graph").get_chat(cid, function(full, err)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        if err or not full then
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { title, "", "_failed to load members: " .. tostring(err):sub(1, 120) .. "_" })
          return
        end
        local fm = nv(full.members)
        if fm and type(fm) == "table" and #fm > 0 then
          chat.members = fm -- enrich for next time
          render_members(fm)
        else
          -- fallback: /members endpoint shape {value=[...]} or bare list
          local alt = nv(full.value)
          if alt and type(alt) == "table" and #alt > 0 then
            chat.members = alt
            render_members(alt)
          else
            render_members(nil)
          end
        end
      end)
    end)
  end
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", function() vim.api.nvim_buf_delete(buf, { force = true }) end, { buffer = buf })
end

function M.reply(chat)
  local chat_id = chat and nv(chat.id) or nil
  if not chat_id then
    local ok, v = pcall(vim.api.nvim_buf_get_var, 0, "ms_teams_chat_id")
    if ok then chat_id = nv(v) or v end
  end
  if not chat_id then
    vim.notify("no chat selected", vim.log.levels.ERROR)
    return
  end
  vim.ui.input({ prompt = "Reply to " .. chat_id:sub(1, 8) .. ": " }, function(text)
    if not text or text == "" then return end
    graph.send_message(chat_id, text, function(res, err)
      if err then
        vim.notify("send failed: " .. err, vim.log.levels.ERROR)
        return
      end
      vim.notify("sent", vim.log.levels.INFO)
      -- invalidate messages cache so next open shows fresh (Teams optimistic update)
      local ok, cache = pcall(require, "ms-teams.cache")
      if ok and chat_id then
        local safe = chat_id:gsub("[^%w%-_:.]", "_"):sub(1, 60)
        local path = vim.fn.stdpath("cache") .. "/ms-teams/messages_" .. safe .. ".json"
        pcall(vim.fn.delete, path)
      end
      -- refresca en la misma ventana, no split horizontal (antes hacía split y abría el mismo buffer abajo)
      if chat then
        -- si estamos ya en el buffer del chat, recarga in-place
        local cur = vim.api.nvim_get_current_buf()
        local ok2, cur_id = pcall(vim.api.nvim_buf_get_var, cur, "ms_teams_chat_id")
        if ok2 and cur_id == chat_id then
          -- fuerza reload sin cambiar layout
          M.show_messages(chat, "current")
        else
          M.show_messages(chat, "current")
        end
      else
        -- reply desde pick sin chat obj: busca el buf del chat y recárgalo si existe
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(b) then
            local ok2, bid = pcall(vim.api.nvim_buf_get_var, b, "ms_teams_chat_id")
            if ok2 and bid == chat_id then
              local c2
              pcall(function() c2 = vim.api.nvim_buf_get_var(b, "ms_teams_chat") end)
              if c2 then M.show_messages(c2, "current") end
              break
            end
          end
        end
      end
    end)
  end)
end

function M.new_chat()
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_conf, conf = pcall(require, "telescope.config")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_action_state, action_state = pcall(require, "telescope.actions.state")

  if not (ok_pickers and ok_finders and ok_conf and ok_actions and ok_action_state) then
    vim.notify("telescope.nvim is required for MSTeamsNewChat", vim.log.levels.ERROR)
    return
  end

  -- live server-side search (official Teams does typeahead via /users $filter/$search)
  local debounce = nil
  local cached_items = {}
  local function to_items(users)
    local items = {}
    for _, u in ipairs(users or {}) do
      if u ~= vim.NIL and nv(u.id) then
        local name = nv(u.displayName) or "Unknown"
        local mail = nv(u.mail) or nv(u.userPrincipalName) or ""
        table.insert(items, { id = nv(u.id), name = name, mail = mail, display = string.format("%-30s | %s", name, mail) })
      end
    end
    return items
  end
  local finder = finders.new_table({ results = {}, entry_maker = function(entry) return { value = entry, display = entry.display, ordinal = entry.name .. " " .. entry.mail } end })
  local picker = pickers.new({}, {
      prompt_title = "Teams New Chat (escribe para buscar en servidor)",
      finder = finder,
      sorter = conf.values.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if not selection or not selection.value then return end
          local target_user = selection.value
          vim.notify("Creating / opening chat with " .. target_user.name .. "...", vim.log.levels.INFO)
          graph.create_chat(target_user.id, function(chat, err2)
            if err2 or not chat then
              vim.notify("Failed to create chat: " .. tostring(err2), vim.log.levels.ERROR)
              return
            end
            vim.notify("Chat opened with " .. target_user.name, vim.log.levels.INFO)
            M.show_messages(chat, "split")
          end)
        end)
        -- live server-side search as you type (like Teams typeahead)
        local function refresh_picker(query)
          graph.list_users(query ~= "" and query or nil, function(users, err)
            if err then return end
            local items = to_items(users)
            cached_items = items
            local picker = action_state.get_current_picker(prompt_bufnr)
            if picker then
              picker:refresh(finders.new_table({
                results = items,
                entry_maker = function(entry) return { value = entry, display = entry.display, ordinal = entry.name .. " " .. entry.mail } end,
              }), { reset_prompt = false })
            end
          end)
        end
        vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
          buffer = prompt_bufnr,
          callback = vim.schedule_wrap(function()
            local line = action_state.get_current_line()
            if debounce then debounce:stop(); debounce:close() end
            debounce = vim.uv.new_timer()
            debounce:start(300, 0, vim.schedule_wrap(function()
              refresh_picker(line)
              if debounce then debounce:stop(); debounce:close(); debounce=nil end
            end))
          end),
        })
        -- initial load top 50
        refresh_picker(nil)
        return true
      end,
    }):find()
end

function M.find_chats(opts)
  opts = opts or {}
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_conf, conf = pcall(require, "telescope.config")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_action_state, action_state = pcall(require, "telescope.actions.state")

  if not (ok_pickers and ok_finders and ok_conf and ok_actions and ok_action_state) then
    vim.notify("telescope.nvim is required for MSTeamsFind", vim.log.levels.ERROR)
    return
  end

  local cache = require("ms-teams.cache")
  local cached = cache.load("chats", 300)

  local function open_picker(chats)
    if not chats or #chats == 0 then
      vim.notify("No chats found", vim.log.levels.WARN)
      return
    end

    local hidden_path = require("ms-teams.config").options.data_dir .. "/hidden.json"
    local hidden_set = {}
    if vim.fn.filereadable(hidden_path) == 1 then
      local ok, j = pcall(vim.json.decode, table.concat(vim.fn.readfile(hidden_path), "\n"))
      if ok and j then
        for _, id in ipairs(j) do hidden_set[id] = true end
      end
    end

    local valid_chats = {}
    for _, c in ipairs(chats) do
      if c ~= vim.NIL and nv(c.id) and not hidden_set[nv(c.id)] then
        if nv(c.chatType) ~= "meeting" or vim.g.ms_teams_show_meeting then
          table.insert(valid_chats, c)
        end
      end
    end

    table.sort(valid_chats, function(a, b)
      if nv(a.id) == "48:notes" then return true end
      if nv(b.id) == "48:notes" then return false end
      local ap = nv(a.lastMessagePreview) and nv(nv(a.lastMessagePreview).createdDateTime)
      local bp = nv(b.lastMessagePreview) and nv(nv(b.lastMessagePreview).createdDateTime)
      local al = ap or nv(a.lastUpdatedDateTime) or ""
      local bl = bp or nv(b.lastUpdatedDateTime) or ""
      return al > bl
    end)

    local top_n = require("ms-teams.config").options.chat_search_top or 500
    local top50 = {}
    for i = 1, math.min(top_n, #valid_chats) do
      table.insert(top50, valid_chats[i])
    end

    local show_all = true -- default: show all chats, <C-b> toggles to unread only

    local function make_items(include_read)
      local items = {}
      for _, c in ipairs(top50) do
        local unread = has_unread(c)
         if include_read or unread then
           local base = format_chat(c)
           local type_icon = get_chat_type_icon(c)
           local icon_prefix = type_icon ~= "" and (type_icon .. "  ") or ""
           local display_name = icon_prefix .. base
          local prefix = unread and "● " or "  "
          table.insert(items, {
            chat = c,
            name = base,
            display_name = display_name,
            unread = unread,
            display = prefix .. display_name,
          })
        end
      end
      return items
    end

    local function create_finder(include_read)
      local items = make_items(include_read)
      return finders.new_table({
        results = items,
        entry_maker = function(entry)
          return {
            value = entry.chat,
            display = entry.display,
            ordinal = to_ascii(entry.name) .. " " .. entry.name,
          }
        end,
      })
    end

    local title_suffix = function()
      return show_all and (" (All "..#top50.." - <C-b> unread only)") or (" (Unread "..#top50.." - <C-b> show all)")
    end

    pickers.new({}, {
      prompt_title = "Teams Chats" .. title_suffix(),
      finder = create_finder(show_all),
      sorter = conf.values.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        local function open_selection(open_mode)
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection and selection.value then
            M.show_messages(selection.value, open_mode)
          end
        end

        actions.select_default:replace(function() open_selection("current") end)
        actions.select_horizontal:replace(function() open_selection("split") end)
        actions.select_vertical:replace(function() open_selection("vsplit") end)

        map({ "i", "n" }, "<C-s>", function() open_selection("split") end)
        map({ "i", "n" }, "<C-v>", function() open_selection("vsplit") end)

        -- <C-b> toggle between unread only and all
        map({ "i", "n" }, "<C-b>", function()
          show_all = not show_all
          local current_picker = action_state.get_current_picker(prompt_bufnr)
          current_picker:refresh(create_finder(show_all), { reset_prompt = false })
          current_picker.prompt_border:change_title("Teams Chats" .. title_suffix())
        end)
        -- disable quickfix for chat entries (not file-based)
        map({ "i", "n" }, "<C-q>", function() vim.notify("quickfix not supported for chats", vim.log.levels.INFO) end)
        map({ "i", "n" }, "<M-q>", function() vim.notify("quickfix not supported for chats", vim.log.levels.INFO) end)
        -- enrich oneOnOne without members so Rubén etc show real name and are searchable via rub
        vim.defer_fn(function()
          local need = {}
          for _, c in ipairs(valid_chats) do
            if nv(c.chatType) == "oneOnOne" and format_chat(c):match("^oneOnOne") then table.insert(need, c) end
          end
          if #need == 0 then return end
          local pending = #need
          for _, c in ipairs(need) do
            require("ms-teams.graph").get_chat(nv(c.id), function(full)
              if full and full.members then c.members = full.members end
              pending = pending - 1
              if pending == 0 then
                vim.schedule(function()
                  if vim.api.nvim_buf_is_valid(prompt_bufnr) then
                    local picker = action_state.get_current_picker(prompt_bufnr)
                    if picker then picker:refresh(create_finder(show_all), {reset_prompt=false}) end
                  end
                end)
              end
            end)
          end
        end, 100)

        return true
      end,
    }):find()
  end

  if cached and cached.chats and #cached.chats > 0 and #cached.chats >= 50 then
    open_picker(cached.chats)
    -- background refresh to get full 123 if cached is partial
    vim.defer_fn(function()
      graph.list_chats(function(chats, err)
        if chats and #chats > #cached.chats then
          cache.save("chats", { chats = chats })
        end
      end, { all = true, limit = 100 })
    end, 500)
    return
  elseif cached and cached.chats and #cached.chats > 0 then
    -- cached but small (e.g., 61), fetch fresh to get all 123
    vim.notify("Loading chats...", vim.log.levels.INFO)
    graph.list_chats(function(chats, err)
      if chats and #chats > 0 then
        cache.save("chats", { chats = chats })
        open_picker(chats)
      else
        open_picker(cached.chats)
      end
    end, { all = true, limit = 100 })
    return
  end

  vim.notify("Loading chats...", vim.log.levels.INFO)
  graph.list_chats(function(chats, err)
    if err or not chats then
      vim.notify("Failed to load chats: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    cache.save("chats", { chats = chats })
    open_picker(chats)
  end, { all = true, limit = 100 })
end

function M.pick_teams()
  local cache = require("ms-teams.cache")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  set_listed_scratch(buf, "ms-teams://teams")
  local current_filter = nil
  local show_all_limit = false
  local teams_data = nil
  local channels_map = {}
  local function clean(s)
    local t = (nv(s) or ""):gsub("\n", " "):gsub("\r", " ")
    return t
  end
  local function load_all_channels(teams, cb)
    local pending = #teams
    if pending == 0 then
      if cb then cb() end
      return
    end
    for _, team in ipairs(teams) do
      require("ms-teams.graph").list_channels(team.id, function(channels, err)
        if err then
          vim.schedule(function() vim.notify("ms-teams list_channels for " .. tostring(team.id) .. ": " .. tostring(err), vim.log.levels.ERROR) end)
        end
        channels_map[team.id] = channels or {}
        pending = pending - 1
        if pending == 0 then
          if cb then cb() end
        end
      end)
    end
  end
  local line_map = {}
  local function render_and_bind(teams, is_cached)
    teams_data = teams
    line_map = {}
    if not teams or #teams == 0 then
      local header = "# Teams (" .. #teams .. ")"
        .. (current_filter and current_filter ~= "" and ' | filter: "' .. clean(current_filter) .. '"' or "")
        .. (is_cached and " - cached" or "")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { header, "", "_no teams found_ — / para buscar, R refresh, q close", "" })
      return
    end
    local lines = {
      "# Teams (" .. #teams .. ")"
        .. (current_filter and current_filter ~= "" and ' | filter: "' .. clean(current_filter) .. '"' or "")
        .. (is_cached and " - cached" or "")
        .. (show_all_limit and " - all teams" or " - top 20")
        .. "",
      "Press <CR> open, <C-s> split, <C-v> vsplit, / search, R refresh, q close",
      "",
    }
    local sorted = vim.deepcopy(teams)
    table.sort(sorted, function(a, b)
      return (a.displayName or ""):lower() < (b.displayName or ""):lower()
    end)
    local unread_by_id = {}
    local cc = cache.load("chats", 300)
    if cc and cc.chats then for _, c in ipairs(cc.chats) do if has_unread(c) then unread_by_id[nv(c.id)] = true end end end
    local unread_lines = {}
    local count = 0
    local max_teams = show_all_limit and #sorted or math.min(#sorted, 20)
    local lnum = #lines
    for _, team in ipairs(sorted) do
      if count >= max_teams then break end
      local channels = channels_map[team.id] or {}
      local team_has_unread = false
      for _, ch in ipairs(channels) do if ch ~= vim.NIL and unread_by_id[nv(ch.id)] then team_has_unread = true; break end end
      table.insert(lines, "## " .. clean(team.displayName) .. " (" .. #channels .. ")")
      lnum = #lines
      line_map[lnum] = { type = "team", team = team }
      if team_has_unread then unread_lines[lnum] = true end
      local channel_icon_teams = get_chat_type_icon({ chatType = "channel" })
      for _, ch in ipairs(channels) do
        if ch ~= vim.NIL and nv(ch.id) then
          local ch_name_teams = clean(ch.displayName)
          table.insert(lines, channel_icon_teams ~= "" and (channel_icon_teams .. "  " .. ch_name_teams) or ch_name_teams)
          lnum = #lines
          line_map[lnum] = { type = "channel", team = team, channel = ch }
          if unread_by_id[nv(ch.id)] then unread_lines[lnum] = true end
        end
      end
      if #channels == 0 then
        table.insert(lines, "  _no channels_")
        line_map[#lines] = { type = "team", team = team }
      end
      table.insert(lines, "")
      lnum = #lines
      count = count + 1
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("ms_teams_unread")
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local hl_group = get_unread_hl_group()
    for l, _ in pairs(unread_lines) do vim.api.nvim_buf_add_highlight(buf, ns, hl_group, l-1, 0, eol_col(buf, l)) end
    vim.api.nvim_buf_set_var(buf, "ms_teams_teams", teams)
    vim.api.nvim_buf_set_var(buf, "ms_teams_render_and_bind", render_and_bind)
  end
  local function open_channel(entry, open_mode)
    if not entry or entry.type ~= "channel" then return end
    local ch = entry.channel
    local team = entry.team
    local channel_topic = nv(ch.displayName) or ch.id
    local channel_chat = {
      id = ch.id, chatType = "channel", topic = channel_topic,
      teamId = nv(team.id), members = {}, lastMessagePreview = nil, displayName = channel_topic,
    }
    M.show_messages(channel_chat, open_mode)
  end
  local function do_search(q)
    if not q or q == "" then
      render_and_bind(teams_data, false)
      return
    end
    q = q:lower()
    local filtered = {}
    for _, t in ipairs(teams_data or {}) do
      local name = (nv(t.displayName) or ""):lower()
      local desc = (nv(t.description) or ""):lower()
      if name:find(q, 1, true) or desc:find(q, 1, true) then
        table.insert(filtered, t)
      end
    end
    render_and_bind(filtered, false)
    vim.notify(string.format("found %d/%d teams", #filtered, #teams_data), vim.log.levels.INFO)
  end
  if cached and cached.teams and #cached.teams > 0 then
    teams_data = cached.teams
    channels_map = cache.load("teams_channels") or {}
    render_and_bind(teams_data, true)
    vim.defer_fn(function()
      require("ms-teams.graph").list_teams(function(new_teams, err)
        if err or not new_teams then return end
        cache.save("teams", { teams = new_teams })
        load_all_channels(new_teams, function()
          cache.save("teams_channels", channels_map)
          if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find("ms%-teams://teams") then
            render_and_bind(new_teams, false)
            vim.notify("teams updated (press R)", vim.log.levels.INFO)
          end
        end)
      end)
    end, 200)
    vim.keymap.set("n", "g/", function()
      vim.ui.input({ prompt = "Search teams: " }, function(q) do_search(q) end)
    end, { buffer = buf })
    vim.keymap.set("n", "R", function()
      require("ms-teams.graph").list_teams(function(new_teams, err)
        if err then vim.notify("refresh failed: " .. err, vim.log.levels.ERROR); return end
        cache.save("teams", { teams = new_teams })
        load_all_channels(new_teams, function()
          cache.save("teams_channels", channels_map)
          render_and_bind(new_teams, false)
          vim.notify(string.format("refreshed %d teams", #new_teams), vim.log.levels.INFO)
        end)
      end)
    end, { buffer = buf })
    vim.keymap.set("n", "q", function() vim.api.nvim_buf_delete(buf, { force = true }) end, { buffer = buf })
    vim.keymap.set("n", "<CR>", function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      open_channel(line_map[lnum], "current")
    end, { buffer = buf })
    vim.keymap.set("n", "<C-s>", function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      open_channel(line_map[lnum], "split")
    end, { buffer = buf })
    vim.keymap.set("n", "<C-v>", function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      open_channel(line_map[lnum], "vsplit")
    end, { buffer = buf })
    return
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Teams", "", "Loading teams...", "" })
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "<CR>", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    open_channel(line_map[lnum], "current")
  end, { buffer = buf })
  vim.keymap.set("n", "<C-s>", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    open_channel(line_map[lnum], "split")
  end, { buffer = buf })
  vim.keymap.set("n", "<C-v>", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    open_channel(line_map[lnum], "vsplit")
  end, { buffer = buf })
  vim.keymap.set("n", "g/", function()
    vim.ui.input({ prompt = "Search teams: " }, function(q) do_search(q) end)
  end, { buffer = buf })
  vim.keymap.set("n", "R", function()
    require("ms-teams.graph").list_teams(function(new_teams, err)
      if err then vim.notify("refresh failed: " .. err, vim.log.levels.ERROR); return end
      cache.save("teams", { teams = new_teams })
      load_all_channels(new_teams, function()
        cache.save("teams_channels", channels_map)
        render_and_bind(new_teams, false)
        vim.notify(string.format("refreshed %d teams", #new_teams), vim.log.levels.INFO)
      end)
    end)
  end, { buffer = buf })
  vim.keymap.set("n", "q", function() vim.api.nvim_buf_delete(buf, { force = true }) end, { buffer = buf })
  require("ms-teams.graph").list_teams(function(teams, err)
    if err then vim.notify("ms-teams list_teams: " .. tostring(err), vim.log.levels.ERROR); return end
    cache.save("teams", { teams = teams })
    load_all_channels(teams, function()
      cache.save("teams_channels", channels_map)
      render_and_bind(teams, false)
    end)
  end)
end

return M
