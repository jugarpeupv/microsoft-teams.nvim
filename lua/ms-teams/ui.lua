local graph = require("ms-teams.graph")

local M = {}

local function nv(v)
  if v == vim.NIL then return nil end
  return v
end

local function get_unread_hl_group()
  local cfg = require("ms-teams.config").options
  if cfg and cfg.highlights and cfg.highlights.unread and cfg.highlights.unread ~= "" then
    return cfg.highlights.unread
  end
  return "DiagnosticInfo"
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

local function has_unread(chat)
  local cache = require("ms-teams.cache")
  local override = cache.get_last_read(nv(chat.id))
  local lr = override
  if not lr then
    local vp = nv(chat.viewpoint)
    lr = vp and nv(vp.lastMessageReadDateTime)
  end
  if not lr then return false end
  local preview = nv(chat.lastMessagePreview)
  local lu = preview and nv(preview.createdDateTime) or nv(chat.lastUpdatedDateTime)
  if not lu then return false end
  if lu <= lr then return false end
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
  if body ~= "" or #img_srcs > 0 then
    if reply_preview then
      table.insert(lines, "  " .. string.format("_↳ reply to: %s_", reply_preview))
    end
    if body ~= "" then
      for line in body:gmatch("[^\n]+") do
        table.insert(lines, "  " .. line)
      end
    end
  else
    if deleted then
      table.insert(lines, "  " .. string.format("_Message deleted on %s_", format_date(deleted)))
    elseif atts and type(atts) == "table" and #atts > 0 then
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
          fname = fname:gsub("%%20"," "):gsub("%%2E","."):gsub("%%5F","_")
          if fname == "" then fname = hid ~= "0" and hid:sub(1,20) or "file" end
          local host = contentUrl:match("https://([^/]+)/") or src:match("https://([^/]+)/") or "graph.microsoft.com"
          table.insert(lines, string.format("  [File: %s (%s) - press gx to open]", fname, host))
        elseif ct == "messageReference" then table.insert(lines, "  [Reference to message]")
        else table.insert(lines, "  " .. string.format("[Attachment: %s]", ct)) end
        ::ac::
      end
      if #atts == 0 then table.insert(lines, "  [Attachment with no body]") end
    elseif hosted and type(hosted) == "table" and #hosted > 0 then
      local hid = nv(hosted[1].id) or nv(hosted[1].contentId) or "0"
      local src = is_channel and string.format("https://graph.microsoft.com/v1.0/teams/%s/channels/%s/messages/%s/hostedContents/%s/$value", team_id or "", chat_id, mid or "", hid) or string.format("https://graph.microsoft.com/v1.0/chats/%s/messages/%s/hostedContents/%s/$value", chat_id, mid or "", hid)
      table.insert(img_srcs, src)
      local host = src:match("https://([^/]+)/") or "graph.microsoft.com"
      table.insert(lines, string.format("  [File: %s (%s) - press gx to open]", hid:sub(1,20), host))
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

function M.pick_chats()
  local cache = require("ms-teams.cache")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  set_listed_scratch(buf, "ms-teams://list-chats")
  local cached = cache.load("chats", 300)
  local current_filter = nil -- shown in header
  local show_all_limit = false -- toggled by gS
  local show_unread_only = false -- toggled by U
  if vim.g.ms_teams_show_meeting == nil then vim.g.ms_teams_show_meeting = true end
  local enriching = false
  local enriched = {}
  local teams_data = nil
  local channels_map = {}
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
  do
    local tc = cache.load("teams", 300)
    if tc and tc.teams then teams_data = tc.teams; channels_map = cache.load("teams_channels") or {} end
  end
  -- render inmediato con cache (sin red), highlight async después
  if teams_data and next(channels_map) ~= nil then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        local ok, all = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_all_chats")
        if ok and all then render_and_bind(all, all, false, current_filter or "") end
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
                if ok and all then render_and_bind(all, all, false, current_filter or "") end
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
              if ok and all then render_and_bind(all, all, false, current_filter or "") end
            end
          end)
        end)
      end, 5000)
    end
  end, 0)
  render_and_bind = function(chats, all_chats, is_cached, filter_term)
    local cur_lnum = vim.api.nvim_win_get_cursor(0)[1]
    if filter_term ~= nil then current_filter = filter_term end
    if not chats or #chats == 0 then
      -- keep header with filter info even when empty
      local empty_header = "# Teams chats (0/" .. #(all_chats or chats) .. " shown"
        .. (current_filter and current_filter ~= "" and ' | filter: "' .. current_filter .. '"' or "")
        .. (is_cached and " - cached" or "") .. ")"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { empty_header, "", "_no matches_ — / para buscar, R refresh, q close", "" })
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
      local line = format_chat(chat)
      if nv(chat.chatType) == "meeting" then line = line .. " (meeting)" end
      table.insert(lines, line)
      local lnum = #lines
      line_to_chat[lnum] = chat
      line_to_entry[lnum] = {type="chat", chat=chat}
      if has_unread(chat) then unread_lines[lnum] = true end
    end
    -- Teams section at bottom
    if teams_data and #teams_data > 0 then
      table.insert(lines, "")
      table.insert(lines, "# Teams (" .. #teams_data .. ")")
      local teams_header_lnum = #lines - 1
      local sorted_teams = vim.deepcopy(teams_data)
      table.sort(sorted_teams, function(a,b) return (a.displayName or ""):lower() < (b.displayName or ""):lower() end)
      for _, team in ipairs(sorted_teams) do
        local channels = channels_map[team.id] or {}
        local team_has_unread = false
        for _, c in ipairs(all_for_search) do
          if nv(c.chatType) == "channel" and nv(c.teamId) == nv(team.id) and unread_by_id[nv(c.id)] then team_has_unread = true; break end
        end
        if not team_has_unread then
          for _, ch in ipairs(channels) do if ch ~= vim.NIL and unread_by_id[nv(ch.id)] then team_has_unread = true; break end end
        end
        table.insert(lines, clean(team.displayName) .. " (" .. #channels .. ")")
        local lnum = #lines
        line_to_entry[lnum] = {type="team", team=team}
        if team_has_unread then unread_lines[lnum] = true end
      end
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("ms_teams_unread")
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local hl_group = get_unread_hl_group()
    for lnum,_ in pairs(unread_lines) do vim.api.nvim_buf_add_highlight(buf, ns, hl_group, lnum-1,0,-1) end
    vim.api.nvim_buf_set_var(buf, "ms_teams_chats", display)
    vim.api.nvim_buf_set_var(buf, "ms_teams_line_to_chat", line_to_chat)
    vim.api.nvim_buf_set_var(buf, "ms_teams_line_to_entry", line_to_entry)
    vim.api.nvim_buf_set_var(buf, "ms_teams_all_chats", all_for_search)
    vim.api.nvim_buf_set_var(buf, "ms_teams_render_and_bind", render_and_bind)
    vim.api.nvim_buf_set_var(buf, "ms_teams_teams", teams_data)
    if vim.api.nvim_get_current_buf() == buf then
      pcall(vim.api.nvim_win_set_cursor, 0, {math.max(1, math.min(cur_lnum, #lines)), 0})
    end
    -- :e detaches treesitter synchronously before BufReadCmd; re-assert after every render
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "markdown" then
        pcall(vim.treesitter.start, buf)
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
                    render_and_bind(all_for_search, all_for_search, false, current_filter or "")
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
    vim.api.nvim_create_autocmd("BufReadCmd", { buffer = buf, callback = function()
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
  if cached and cached.chats and #cached.chats>0 then
    vim.api.nvim_buf_set_lines(buf,0,-1,false,{"# Teams chats (cached)","", "Loading chats...",""})
    vim.api.nvim_win_set_buf(0, buf)
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
  vim.api.nvim_buf_set_lines(buf,0,-1,false,{"# Teams chats","","Loading chats...",""})
  vim.api.nvim_win_set_buf(0, buf)
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
              vim.api.nvim_buf_add_highlight(b, ns, hl_group, lnum - 1, 0, -1)
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
    local is_cached = opts.is_cached
    if not msgs then msgs = {} end
    local buf = opts.buf
    local reuse = buf and vim.api.nvim_buf_is_valid(buf)
    if not reuse then
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
    end
    local title = format_chat(chat) or nv(chat.topic) or nv(chat.chatType) or chat_id
    local safe_id = safe_id_cache
    local chat_name = title
    local safe_name = to_ascii(chat_name):gsub("[^%w%-_ %.]", "_"):gsub("%s+", "-"):sub(1, 40)
    set_listed_scratch(buf, "ms-teams://chat/" .. safe_name .. "__" .. safe_id)
    local HEADER_LINES = 6
    local header_suffix = is_cached and " (cached)" or ""
    local lines = { "# " .. chat_name, "", string.format("Chat: %s | %d messages%s", chat_id, #msgs, header_suffix), "", "Press g? participants | S reply | R refresh | gR load 50 older | mr mark read | mu mark unread | q close | <CR> jump reply", "" }
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
    table.insert(lines, "Hints: q close | S reply (<C-p> paste img) | R refresh | g? participants | mr mark read | mu mark unread | gR load 50 older | <CR> jump to original")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("ms_teams_msg_unread")
    local hl_group = get_unread_hl_group()
    for lnum, _ in pairs(unread_msg_lines) do
      vim.api.nvim_buf_add_highlight(buf, ns, hl_group, lnum - 1, 0, -1)
    end

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
    if target then
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(buf) then
          local win = vim.fn.bufwinid(buf)
          if win ~= -1 then
            pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
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
      loading = true
      vim.notify("loading 50 older messages...", vim.log.levels.INFO)
      vim.api.nvim_buf_set_lines(buf, HEADER_LINES, HEADER_LINES, false, {"_Loading 50 more..._"})
      do_list_messages(chat_id, function(more, err2, next2)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buf) then loading=false; return end
          pcall(vim.api.nvim_buf_set_lines, buf, HEADER_LINES, HEADER_LINES+1, false, {})
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
          render_buffer(combined, next2, { is_cached = false, buf = buf, no_open = true })

          local win = vim.fn.bufwinid(buf)
          if win ~= -1 then
            pcall(vim.api.nvim_win_set_cursor, win, { HEADER_LINES + 1, 0 })
          end
          vim.notify(string.format("loaded %d older messages (%d total)%s", #more, #combined, (next2 and next2~="" and "" or " - all loaded")), vim.log.levels.INFO)
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
        src = img_map[lnum]
      else
        vim.notify("image src not found, try reopening chat", vim.log.levels.WARN)
        return
      end
      -- SharePoint files (personal docs) need browser, not Bearer token (aud mismatch)
      if src:find("sharepoint%.com") then
        vim.notify("opening SharePoint file in browser...", vim.log.levels.INFO)
        if vim.ui and vim.ui.open then vim.ui.open(src) else vim.fn.jobstart({"open", src}, {detach=true}) end
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
    vim.keymap.set("n", "mr", function()
      local cur_pos = vim.api.nvim_win_get_cursor(0)
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
                          render_buffer(fresh, freshNext, { is_cached = false, buf = buf, no_open = true, target_cursor = cur_pos[1] })
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
      local lnum = cur_pos[1]
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
                      render_buffer(fresh, freshNext, { is_cached = false, buf = buf, no_open = true, target_cursor = cur_pos[1] })
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
  local members = nv(chat.members)
  if not members or type(members) ~= "table" or #members == 0 then
    vim.notify("no participants cached", vim.log.levels.INFO)
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  set_listed_scratch(buf, "ms-teams://chat/" .. (nv(chat.id) or "unknown"):gsub("[^%w%-_:.]", "_"):sub(1, 50) .. "/participants")
  local lines = { "# Participants: " .. (nv(chat.topic) or nv(chat.chatType) or nv(chat.id) or "chat"), "" }
  if members and type(members) == "table" then
    for _, m in ipairs(members) do
      if m == vim.NIL then goto cont end
      local name = nv(m.displayName) or "unknown"
      local email = nv(m.email) or ""
      local userId = nv(m.userId) or ""
      table.insert(lines, string.format("- %s%s%s", name, email ~= "" and " <" .. email .. ">" or "", userId ~= "" and " (" .. userId:sub(1, 8) .. ")" or ""))
      ::cont::
    end
  else
    table.insert(lines, "_no member info - chatType: " .. (nv(chat.chatType) or "unknown") .. "_")
    table.insert(lines, "id: " .. (nv(chat.id) or ""))
  end
  if #lines == 2 then table.insert(lines, "_no participants_") end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
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
          local name = format_chat(c)
          local prefix = unread and "● " or "  "
          table.insert(items, {
            chat = c,
            name = name,
            unread = unread,
            display = prefix .. name,
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
      for _, ch in ipairs(channels) do
        if ch ~= vim.NIL and nv(ch.id) then
          table.insert(lines, clean(ch.displayName))
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
    for l, _ in pairs(unread_lines) do vim.api.nvim_buf_add_highlight(buf, ns, hl_group, l-1, 0, -1) end
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
