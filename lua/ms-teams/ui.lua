local graph = require("ms-teams.graph")

local M = {}

local function nv(v)
  if v == vim.NIL then return nil end
  return v
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
  -- detect <img> for image.nvim (Teams hostedContents) before stripping tags
  local img_srcs = {}
  for src in body:gmatch('<img[^>]+src="([^"]+)"') do table.insert(img_srcs, src) end
  for src in body:gmatch("<img[^>]+src='([^']+)'") do table.insert(img_srcs, src) end

  -- 1. Extract and preserve codeblocks: <codeblock class="Language"><code>...</code></codeblock>
  local codeblocks = {}
  body = body:gsub("<codeblock%s*class=[\"']([^\"']*)[\"'][^>]*>%s*<code>(.-)</code>%s*</codeblock>", function(lang, code)
    table.insert(codeblocks, { lang = lang or "", code = code })
    return "\001CB" .. #codeblocks .. "\001"
  end)
  body = body:gsub("<codeblock[^>]*>%s*<code>(.-)</code>%s*</codeblock>", function(code)
    table.insert(codeblocks, { lang = "", code = code })
    return "\001CB" .. #codeblocks .. "\001"
  end)

  -- 2. Extract and preserve inline code: <code>...</code>
  local inline_codes = {}
  body = body:gsub("<code>(.-)</code>", function(code)
    table.insert(inline_codes, code)
    return "\002IN" .. #inline_codes .. "\002"
  end)

  -- 3. Handle emojis & structure tags
  body = body:gsub('<emoji[^>]+alt="([^"]+)"[^>]*></emoji>', "%1")
  body = body:gsub("<emoji[^>]+alt='([^']+)'[^>]*></emoji>", "%1")
  body = body:gsub('<emoji[^>]+alt="([^"]+)"[^>]*/>', "%1")
  body = body:gsub("<br%s*/?>", "\n")
  body = body:gsub("</p>", "\n")
  body = body:gsub("<[^>]+>", "")
  body = body:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
  body = body:gsub("\226\128\131", " ") -- U+2003 em space

  -- 4. Restore inline codes
  body = body:gsub("\002IN(%d+)\002", function(idx)
    local code = inline_codes[tonumber(idx)] or ""
    code = code:gsub("<[^>]+>", "")
    code = code:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    code = code:gsub("\226\128\131", " ")
    code = code:gsub("^%s+", ""):gsub("%s+$", "")
    return "`" .. code .. "`"
  end)

  -- 5. Restore codeblocks with markdown triple backticks
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
    for _, src in ipairs(img_srcs) do
      local b64 = src:match("/hostedContents/([^/]+)/")
      local name = "image"
      if b64 then
        name = b64:sub(1,20)
      end
      if src:lower():find("%.gif") then name="gif" end
      table.insert(lines, string.format("  [Image: %s - press gx to open]", name))
    end
  else
    if deleted then
      table.insert(lines, "  " .. string.format("_Message deleted on %s_", format_date(deleted)))
    elseif atts and type(atts) == "table" and #atts > 0 then
      for _, a in ipairs(atts) do
        if a == vim.NIL then goto ac end
        local ct = nv(a.contentType) or "attachment"
        if ct == "reference" then table.insert(lines, "  [Image/File attachment - hostedContent]")
        elseif ct == "messageReference" then table.insert(lines, "  [Reference to message]")
        else table.insert(lines, "  " .. string.format("[Attachment: %s]", ct)) end
        ::ac::
      end
      if #atts == 0 then table.insert(lines, "  [Attachment with no body]") end
    elseif hosted and type(hosted) == "table" and #hosted > 0 then
      table.insert(lines, "  [Multimedia content - hostedContents, requires GET /chats/{id}/messages/{id}/hostedContents/{id}/$value]")
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
  set_listed_scratch(buf, "ms-teams://chats")
  local cached = cache.load("chats", 300)
  local current_filter = nil -- shown in header
  local show_all_limit = false -- toggled by gS
  local show_unread_only = false -- toggled by U
  local enriching = false
  local function render_and_bind(chats, all_chats, is_cached, filter_term)
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
    -- si 48:notes no estaba, ya lo inyectó graph.lua:70, pero asegura que no quede fuera del top 20
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
    if not is_filtering and not show_all_limit and #display > 20 then
      local t = {}
      for i=1,20 do t[i]=display[i] end
      display = t
    end
    local header = "# Teams chats (" .. #display .. "/" .. #all_for_search .. " shown"
      .. (current_filter and current_filter ~= "" and ' | filter: "' .. current_filter .. '"' or "")
      .. (show_unread_only and " - unread only" or "")
      .. (is_cached and " - cached" or "") .. (is_filtering and " - meeting included" or (vim.g.ms_teams_show_meeting and "" or " - meeting hidden, M to show")) .. ")"
    local lines = { header, "", "Press <CR> replace, <C-s> split, <C-v> vsplit, / search, U unread, M meeting, gS show more/less, R refresh, <C-x> hide, q close", "" }
    local line_to_chat = {}
    local unread_lines = {}
    for _, chat in ipairs(display) do
      local line = format_chat(chat)
      table.insert(lines, line)
      line_to_chat[#lines] = chat
      if has_unread(chat) then unread_lines[#lines] = true end
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("ms_teams_unread")
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for lnum,_ in pairs(unread_lines) do vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticInfo", lnum-1,0,-1) end
    vim.api.nvim_buf_set_var(buf, "ms_teams_chats", display)
    vim.api.nvim_buf_set_var(buf, "ms_teams_line_to_chat", line_to_chat)
    vim.api.nvim_buf_set_var(buf, "ms_teams_all_chats", all_for_search)
    vim.api.nvim_buf_set_var(buf, "ms_teams_render_and_bind", render_and_bind)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, {5,0})
    local function open_for(lnum, open)
      local chat = line_to_chat[lnum]
      if not chat or nv(chat.id)==nil then vim.notify("no chat on this line",vim.log.levels.WARN); return end
      M.show_messages(chat, open)
    end
    vim.keymap.set("n", "<CR>", function() open_for(vim.api.nvim_win_get_cursor(0)[1],"current") end, {buffer=buf})
    vim.keymap.set("n", "<C-s>", function() open_for(vim.api.nvim_win_get_cursor(0)[1],"split") end, {buffer=buf})
    vim.keymap.set("n", "<C-v>", function() open_for(vim.api.nvim_win_get_cursor(0)[1],"vsplit") end, {buffer=buf})
    vim.keymap.set("n", "/", function()
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
      vim.notify(show_all_limit and "Showing all chats" or "Showing top 20 chats", vim.log.levels.INFO)
    end, {buffer=buf, desc="Toggle show more/less chats"})
    vim.keymap.set("n", "R", function()
      vim.notify("refreshing...",vim.log.levels.INFO)
      require("ms-teams.graph").list_chats(function(nc,err)
        if err then vim.notify("refresh failed: "..err,vim.log.levels.ERROR); return end
        cache.save("chats",{chats=nc})
        render_and_bind(nc,nc,false,"")
        vim.notify(string.format("refreshed %d chats", #nc), vim.log.levels.INFO)
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
            if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find("ms%-teams://chats") then
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
          if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find("ms%-teams://chats", 1, true) then
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
  local cache = require("ms-teams.cache")
  local safe_id_cache = chat_id:gsub("[^%w%-_:.]", "_"):sub(1, 60)
  local cache_key = "messages_" .. safe_id_cache
  local CACHE_TTL = 45

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
    local title = nv(chat.topic) or nv(chat.chatType) or chat_id
    local safe_id = safe_id_cache
    set_listed_scratch(buf, "ms-teams://chat/" .. safe_id)
    local HEADER_LINES = 6
    local header_suffix = is_cached and " (cached)" or ""
    local lines = { "# " .. title, "", string.format("Chat: %s | %d messages%s", chat_id, #msgs, header_suffix), "", "Press g? participants | S reply | R refresh | gR load 50 older | mr mark read | mu mark unread | q close | <CR> jump reply", "" }
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
        if l:find("%[Image:") and res.img_srcs and #res.img_srcs > 0 then
          -- map this image line to its src (by order, nth image line -> nth src)
          local img_idx = 0
          for _, ll in ipairs(res.lines) do
            if ll:find("%[Image:") then
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
    table.insert(lines, "Hints: q close | S reply | R refresh | g? participants | mr mark read | mu mark unread | gR load 50 older | <CR> jump to original")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("ms_teams_msg_unread")
    for lnum, _ in pairs(unread_msg_lines) do
      vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticInfo", lnum - 1, 0, -1)
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
    local target = first_unread or #lines
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) then
        local win = vim.fn.bufwinid(buf)
        if win ~= -1 then
          pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
        end
      end
    end, 10)

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
      graph.list_messages(chat_id, function(more, err2, next2)
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
               if l:find("%[Image:") and res.img_srcs and #res.img_srcs > 0 then
                 -- map this image line to its src (nth image)
                 local img_idx = 0
                 for _, ll in ipairs(res.lines) do
                   if ll:find("%[Image:") then
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
          graph.list_messages(chat_id, function(fresh, err2, freshNext)
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
      if not line:find("%[Image:") then
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
      vim.notify("downloading image...", vim.log.levels.INFO)
      local token = require("ms-teams.auth").get_token("read")
      if not token then vim.notify("no token", vim.log.levels.ERROR); return end
      local tmp = vim.fn.tempname() .. ".png"
      local out = vim.fn.system({"curl","-s","--max-time","30","-H","Authorization: Bearer "..token, src, "-o", tmp})
      if vim.v.shell_error ~= 0 or vim.fn.getfsize(tmp) < 100 then
        vim.notify("download failed: " .. out, vim.log.levels.ERROR)
        return
      end
      vim.notify("opening with Preview...", vim.log.levels.INFO)
      vim.fn.jobstart({"open", tmp}, {detach=true})
    end, { buffer = buf, desc = "Open image or default gx" })
    vim.keymap.set("n", "mr", function()
      vim.ui.input({ prompt = string.format("Mark whole chat '%s' as read? (y/N): ", format_chat(chat)) }, function(ans)
        if not ans or ans:lower() ~= "y" then vim.notify("cancelled", vim.log.levels.INFO); return end
        vim.notify("marking chat as read...", vim.log.levels.INFO)
        require("ms-teams.graph").mark_chat_read(chat_id, function(_, err)
          local function do_local()
            require("ms-teams.cache").clear_last_read(chat_id)
            chat.viewpoint = chat.viewpoint or {}
            if chat.viewpoint == vim.NIL then chat.viewpoint = {} end
            chat.viewpoint.lastMessageReadDateTime = os.date("!%Y-%m-%dT%H:%M:%SZ")
            vim.schedule(function()
              if vim.api.nvim_buf_is_valid(buf) then
                local ns = vim.b[buf].ms_teams_ns or vim.api.nvim_create_namespace("ms_teams_msg_unread")
                vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
                vim.notify("marked read - Last read marker removed", vim.log.levels.INFO)
                -- auto re-render detail to remove Last read divider and highlights
                vim.defer_fn(function()
                  if vim.api.nvim_buf_is_valid(buf) then
                    -- re-render current chat detail with new lastRead
                    -- we have msgs and nextLink in closure, just re-render via cache
                    local ok, cur_msgs = pcall(vim.api.nvim_buf_get_var, buf, "ms_teams_msgs_cache")
                    -- fallback: re-fetch via Graph and re-render
                    require("ms-teams.graph").list_messages(chat_id, function(fresh, err2, freshNext)
                      if err2 or not fresh then return end
                      vim.schedule(function()
                        if vim.api.nvim_buf_is_valid(buf) then
                          local cache_key2 = "messages_" .. safe_id_cache
                          require("ms-teams.cache").save(cache_key2, {messages=fresh, nextLink=freshNext or ""})
                          render_buffer(fresh, freshNext, { is_cached = false, buf = buf, no_open = true })
                        end
                      end)
                    end)
                  end
                end, 100)
              end
              -- async background refresh of chats list with start/end logs
              vim.defer_fn(function()
                M.refresh_chats_background()
              end, 100)
            end)
          end
          if err then
            do_local()
            vim.notify("marked read locally (" .. err .. ")", vim.log.levels.WARN)
          else
            do_local()
            vim.notify("marked read", vim.log.levels.INFO)
          end
        end)
      end)
    end, { buffer = buf, desc = "Mark chat read (whole chat)" })
    vim.keymap.set("n", "mu", function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
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
        vim.ui.input({ prompt = string.format("Mark message %s as unread? (y/N): ", target_msg_id:sub(1,8)) }, function(ans)
          if not ans or ans:lower() ~= "y" then vim.notify("cancelled", vim.log.levels.INFO); return end
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
          vim.notify("marking as unread on Teams server...", vim.log.levels.INFO)
          require("ms-teams.graph").mark_chat_unread(chat_id, new_last_read, function(_, err_graph)
            if err_graph then
              vim.notify("marked unread locally (" .. err_graph .. ")", vim.log.levels.WARN)
            else
              vim.notify("marked unread on Teams server", vim.log.levels.INFO)
            end
            -- trigger background refresh of chats list buffer with start/end logs
            vim.defer_fn(function()
              M.refresh_chats_background()
            end, 100)
            vim.defer_fn(function()
              if vim.api.nvim_buf_is_valid(buf) then
                require("ms-teams.graph").list_messages(chat_id, function(fresh, err2, freshNext)
                  if err2 then return end
                  vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(buf) then
                      local cache_key2 = "messages_" .. safe_id_cache
                      require("ms-teams.cache").save(cache_key2, {messages=fresh, nextLink=freshNext or ""})
                      render_buffer(fresh, freshNext, { is_cached = false, buf = buf, no_open = true })
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
      graph.list_messages(chat_id, function(fresh, err, freshNext)
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
  end

  -- try cache first (Teams-like instant open)
  local cached = cache.load(cache_key, CACHE_TTL)
  if cached and cached.messages and #cached.messages > 0 then
    render_buffer(cached.messages, cached.nextLink, {is_cached=true, open=open})
    -- stale-while-revalidate: background refresh without blocking UI
    vim.defer_fn(function()
      local last_read_iso = get_last_read_iso(chat)
      graph.list_messages_until_read(chat_id, last_read_iso, function(fresh, err, freshNext)
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
  set_listed_scratch(loading_buf, "ms-teams://chat/" .. safe_id_cache)
  vim.api.nvim_buf_set_lines(loading_buf, 0, -1, false, {"# " .. (nv(chat.topic) or nv(chat.chatType) or chat_id), "", "Loading messages...", ""})
  if open == "current" then vim.api.nvim_win_set_buf(0, loading_buf)
  elseif open == "vsplit" then vim.cmd("vsplit"); vim.api.nvim_win_set_buf(0, loading_buf)
  else vim.cmd("split"); vim.api.nvim_win_set_buf(0, loading_buf) end
  local last_read_iso = get_last_read_iso(chat)
  graph.list_messages_until_read(chat_id, last_read_iso, function(msgs, err, nextLink)
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

  vim.notify("Loading users from organization...", vim.log.levels.INFO)
  graph.list_users(nil, function(users, err)
    if err then
      vim.notify("Failed to list users: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if not users or #users == 0 then
      vim.notify("No users found in organization", vim.log.levels.WARN)
      return
    end

    local items = {}
    for _, u in ipairs(users) do
      if u ~= vim.NIL and nv(u.id) then
        local name = nv(u.displayName) or "Unknown"
        local mail = nv(u.mail) or nv(u.userPrincipalName) or ""
        table.insert(items, {
          id = nv(u.id),
          name = name,
          mail = mail,
          display = string.format("%-30s | %s", name, mail),
        })
      end
    end

    pickers.new({}, {
      prompt_title = "Teams New Chat (Select User)",
      finder = finders.new_table({
        results = items,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.display,
            ordinal = entry.name .. " " .. entry.mail,
          }
        end,
      }),
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
        return true
      end,
    }):find()
  end)
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

    -- Top 50 chats
    local top50 = {}
    for i = 1, math.min(50, #valid_chats) do
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
            ordinal = entry.name,
          }
        end,
      })
    end

    local title_suffix = function()
      return show_all and " (All Top 50 - <C-b> unread only)" or " (Unread Top 50 - <C-b> show all)"
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

        return true
      end,
    }):find()
  end

  if cached and cached.chats and #cached.chats > 0 then
    open_picker(cached.chats)
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

return M
