local config = require("ms-teams.config")
local auth = require("ms-teams.auth")

local M = {}

local function url_encode(s)
  if not s then return "" end
  s = tostring(s)
  s = s:gsub("[^%w%-%.%_~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return s
end

local function graph_request(kind, method, path, body)
  local token, err = auth.get_token(kind)
  if not token then return nil, err end
  local url = config.options.graph_base .. path
  local curl = { "curl", "-s", "--max-time", "60", "-X", method, url, "-H", "Authorization: Bearer " .. token, "-H", "Content-Type: application/json" }
  if body then
    table.insert(curl, "-d")
    table.insert(curl, vim.json.encode(body))
  end
  local out = vim.fn.system(curl)
  if vim.v.shell_error ~= 0 then return nil, out end
  local ok, j = pcall(vim.json.decode, out)
  if not ok then return nil, out end
  if j.error then return nil, j.error.message or vim.inspect(j.error) end
  return j, nil
end

local function graph_request_async(kind, method, path, body, cb)
  auth.ensure_token_async(kind, function(token, err)
    if not token then
      vim.schedule(function() cb(nil, err) end)
      return
    end
    local url = config.options.graph_base .. path
    local cmd = { "curl", "-s", "--max-time", "60", "-X", method, url, "-H", "Authorization: Bearer " .. token, "-H", "Content-Type: application/json" }
    if body then
      table.insert(cmd, "-d")
      table.insert(cmd, vim.json.encode(body))
    end
    vim.system(cmd, { text = true }, function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          local errmsg = "curl exit " .. tostring(obj.code) .. " url: " .. url:sub(1, 300)
          if obj.stderr ~= "" then errmsg = errmsg .. " stderr: " .. obj.stderr end
          if obj.stdout ~= "" then errmsg = errmsg .. " stdout: " .. obj.stdout:sub(1, 200) end
          vim.notify("ms-teams graph_request_async: " .. errmsg, vim.log.levels.ERROR)
          cb(nil, errmsg)
          return
        end
        local ok, j = pcall(vim.json.decode, obj.stdout)
        if not ok then cb(nil, obj.stdout); return end
        if j.error then
          local emsg = j.error.message or vim.inspect(j.error)
          -- If token was revoked/invalidated on Graph side, clear access_token expiry and trigger auth
          if emsg:find("InvalidAuthenticationToken") or emsg:find("CompactToken") or emsg:find("Lifetime validation failed") then
            auth.ensure_token_async(kind, function(new_tok, err_login)
              if new_tok then
                -- retry request once
                graph_request_async(kind, method, path, body, cb)
              else
                cb(nil, emsg)
              end
            end)
            return
          end
          cb(nil, emsg)
          return
        end
        cb(j, nil)
      end)
    end)
  end)
end

function M.list_chats(cb, opts)
  opts = opts or {}
  local top = opts.top or config.options.chat_top
  local do_all = opts.all or false
  local expand = "$expand=lastMessagePreview"
  if not do_all then
    graph_request_async("read", "GET", "/me/chats?$top=" .. top .. "&" .. expand, nil, function(j, err)
      if not j then cb(nil, err); return end
      cb(j.value or {}, nil)
    end)
    return
  end
  local all = {}
  local limit = opts.limit or config.options.chat_search_top or 500
  local function fetch(url)
    graph_request_async("read", "GET", url, nil, function(j, err)
      if not j then
        cb(#all > 0 and all or nil, err)
        return
      end
      for _, c in ipairs(j.value or {}) do table.insert(all, c) end
      if #all >= limit then
        local has_notes=false; for _,c in ipairs(all) do if c.id=="48:notes" then has_notes=true; break end end
        if has_notes then cb(all, nil); return end
        graph_request_async("read","GET","/chats/48:notes?$expand=members",nil,function(n,e)
          if n and n.id then table.insert(all,1,n)
          else
            local me_name = vim.g.ms_teams_me_name or (function() local ok,c=pcall(require("ms-teams.cache").load,"me"); if ok and c and c.displayName then return c.displayName end; return "You" end)()
            local me_mail = vim.g.ms_teams_me_mail or (function() local ok,c=pcall(require("ms-teams.cache").load,"me"); if ok and c and c.mail then return c.mail end; return "you@example.com" end)()
            table.insert(all,1,{id="48:notes", chatType="oneOnOne", topic="", members={{displayName=me_name, email=me_mail}}, lastMessagePreview={createdDateTime="2026-08-29T21:21:41.942Z"}})
          end; cb(all,nil)
        end)
        return
      end
      local nextLink = j["@odata.nextLink"]
      if nextLink and nextLink ~= "" then
        local path = nextLink:gsub("^https://graph.microsoft.com/v1.0", "")
        if #all < limit then fetch(path); return end
      end
      local has_notes=false; for _,c in ipairs(all) do if c.id=="48:notes" then has_notes=true; break end end
      if has_notes then cb(all, nil); return end
      graph_request_async("read","GET","/chats/48:notes?$expand=members",nil,function(n,e)
        if n and n.id then table.insert(all,1,n)
        else
            local me_name2 = vim.g.ms_teams_me_name or (function() local ok,c=pcall(require("ms-teams.cache").load,"me"); if ok and c and c.displayName then return c.displayName end; return "You" end)()
            local me_mail2 = vim.g.ms_teams_me_mail or (function() local ok,c=pcall(require("ms-teams.cache").load,"me"); if ok and c and c.mail then return c.mail end; return "you@example.com" end)()
            table.insert(all,1,{id="48:notes", chatType="oneOnOne", topic="", members={{displayName=me_name2, email=me_mail2}}, lastMessagePreview={createdDateTime="2026-08-29T21:21:41.942Z"}})
        end; cb(all,nil)
      end)
    end)
  end
  fetch("/me/chats?$top=" .. top .. "&" .. expand)
end

function M.list_messages(chat_id, cb, nextLink)
  if nextLink then
    local path = nextLink:gsub("^https://graph.microsoft.com/v1.0", "")
    graph_request_async("read", "GET", path, nil, function(j, err)
      if not j then cb(nil, err, nil); return end
      cb(j.value or {}, nil, j["@odata.nextLink"])
    end)
    return
  end
  local want = config.options.message_top or 50
  local top = math.min(want, 50)
  local path = string.format("/chats/%s/messages?$top=%d", chat_id, top)
  graph_request_async("read", "GET", path, nil, function(j, err)
    if not j then cb(nil, err, nil); return end
    local all = j.value or {}
    if #all >= want or not j["@odata.nextLink"] then
      cb(all, nil, j["@odata.nextLink"])
      return
    end
    local nextPath = j["@odata.nextLink"]:gsub("^https://graph.microsoft.com/v1.0", "")
    graph_request_async("read", "GET", nextPath, nil, function(j2, err2)
      if not j2 then cb(all, nil, j["@odata.nextLink"]); return end
      for _, m in ipairs(j2.value or {}) do
        table.insert(all, m)
        if #all >= want then break end
      end
      cb(all, nil, j2["@odata.nextLink"] or j["@odata.nextLink"])
    end)
  end)
end

function M.list_messages_until_read(chat_id, last_read_iso, cb)
  local all = {}
  local max_pages = 10 -- safety limit: up to 500 messages

  local function fetch_page(path, page_num)
    graph_request_async("read", "GET", path, nil, function(j, err)
      if not j then
        if #all > 0 then cb(all, nil, nil) else cb(nil, err, nil) end
        return
      end
      local page_msgs = j.value or {}
      for _, m in ipairs(page_msgs) do
        table.insert(all, m)
      end

      local nextLink = j["@odata.nextLink"]
      if not nextLink or nextLink == "" or page_num >= max_pages then
        cb(all, nil, nextLink)
        return
      end

      -- If we have last_read_iso, check if the oldest message fetched so far is older than last_read_iso
      if last_read_iso and last_read_iso ~= "" then
        local reached_read = false
        for _, m in ipairs(page_msgs) do
          local ct = m.createdDateTime
          if ct and ct <= last_read_iso then
            reached_read = true
            break
          end
        end

        if reached_read then
          -- We have fetched past the last_read boundary.
          -- Fetch 1 more page if available to give context before last_read, then stop.
          local nextPath = nextLink:gsub("^https://graph.microsoft.com/v1.0", "")
          graph_request_async("read", "GET", nextPath, nil, function(j_extra, _)
            if j_extra and j_extra.value then
              for _, m in ipairs(j_extra.value) do
                table.insert(all, m)
              end
              cb(all, nil, j_extra["@odata.nextLink"])
            else
              cb(all, nil, nextLink)
            end
          end)
          return
        end
      end

      -- If no last_read or not reached yet, continue fetching next page
      local nextPath = nextLink:gsub("^https://graph.microsoft.com/v1.0", "")
      fetch_page(nextPath, page_num + 1)
    end)
  end

  local initial_path = string.format("/chats/%s/messages?$top=50", chat_id)
  fetch_page(initial_path, 1)
end

function M.get_chat(chat_id, cb)
  -- 48:notes y oneOnOne con members truncado (limit=500 quita $expand) necesitan fetch directo
  graph_request_async("read", "GET", "/chats/" .. chat_id .. "?$expand=members", nil, function(j, err)
    if not j then
      -- fallback: /chats/{id}/members
      graph_request_async("read", "GET", "/chats/" .. chat_id .. "/members", nil, function(j2, err2)
        if not j2 then cb(nil, err); return end
        -- normaliza a {members: [...]}
        if j2.value then cb({ id = chat_id, members = j2.value }, nil)
        else cb({ id = chat_id, members = {j2} }, nil) end
      end)
      return
    end
    cb(j, nil)
  end)
end

function M.get_me(cb)
  graph_request_async("read", "GET", "/me?$select=id,displayName,mail", nil, function(j, err)
    if err or not j then cb(nil, err or "no me"); return end
    cb(j, nil)
  end)
end

local function get_user_identity(cb)
  -- saca id/tenant del JWT (oid/tid) sin llamada extra; si falla usa /me
  local auth = require("ms-teams.auth")
  local token = auth.get_token("read")
  local path = config.options.data_dir .. "/token.json"
  if vim.fn.filereadable(path) == 1 then
    local data = vim.fn.readfile(path)
    local ok, j = pcall(vim.json.decode, table.concat(data, "\n"))
    if ok and j and j.access_token then
      local parts = vim.split(j.access_token, ".", { plain = true })
      if #parts >= 2 then
        local b64 = parts[2]:gsub("-", "+"):gsub("_", "/")
        local pad = #b64 % 4
        if pad > 0 then b64 = b64 .. string.rep("=", 4 - pad) end
        local ok2, js = pcall(vim.json.decode, vim.fn.system({ "python3", "-c", "import base64,sys;print(base64.b64decode(sys.argv[1]).decode())", b64 }))
        if ok2 and js and js.tid and (js.oid or js.sub) then
          cb(js.oid or js.sub, js.tid, nil)
          return
        end
      end
    end
  end
  graph_request_async("read", "GET", "/me?$select=id", nil, function(me, err)
    if not me or not me.id then cb(nil, nil, err or "no user id"); return end
    graph_request_async("read", "GET", "/organization?$select=id", nil, function(org, _)
      local tenant = (org and org.value and org.value[1] and org.value[1].id) or ""
      cb(me.id, tenant, nil)
    end)
  end)
end

function M.hide_chat(chat_id, cb)
  if chat_id == "48:notes" then cb(nil, "48:notes (Notes) no se puede ocultar"); return end
  get_user_identity(function(user_id, tenant_id, err)
    if not user_id then cb(nil, err or "could not retrieve user identity"); return end
    local body = { user = { id = user_id, tenantId = tenant_id } }
    graph_request_async("read", "POST", "/chats/" .. chat_id .. "/hideForUser", body, function(j, err2)
      if j or not err2 then cb(j or {}, nil); return end
      -- fallback DELETE para group donde eres owner
      graph_request_async("read", "DELETE", "/chats/" .. chat_id, nil, function(j2, err3)
        if j2 or not err3 then cb(j2 or {}, nil); return end
        cb(nil, err2)
      end)
    end)
  end)
end

function M.list_teams(cb)
  local all = {}
  local function fetch(url)
    graph_request_async("read", "GET", url, nil, function(j, err)
      if not j then
        if #all > 0 then cb(all, nil) else cb(nil, err) end
        return
      end
      for _, t in ipairs(j.value or {}) do table.insert(all, t) end
      local nextLink = j["@odata.nextLink"]
      if nextLink and nextLink ~= "" then
        local path = nextLink:gsub("^https://graph.microsoft.com/v1.0", "")
        fetch(path)
      else
        cb(all, nil)
      end
    end)
  end
  fetch("/me/joinedTeams?%24select=id,displayName,description,webUrl")
end

function M.list_groups(cb)
  -- deprecated: kept for compatibility, delegates to list_teams
  return M.list_teams(cb)
end

function M.list_channels(team_id, cb)
  graph_request_async("read", "GET", "/teams/" .. team_id .. "/channels?$select=id,displayName,description,webUrl", nil, function(j, err)
    if not j then cb(nil, err); return end
    cb(j.value or {}, nil)
  end)
end

function M.list_channel_messages(team_id, channel_id, cb, nextLink)
  if nextLink then
    local path = nextLink:gsub("^https://graph.microsoft.com/v1.0", "")
    graph_request_async("read", "GET", path, nil, function(j, err)
      if not j then cb(nil, err, nil); return end
      cb(j.value or {}, nil, j["@odata.nextLink"])
    end)
    return
  end
  local want = config.options.message_top or 50
  local top = math.min(want, 5)
  local path = string.format("/chats/%s/messages?$top=%d", channel_id, top)
  graph_request_async("read", "GET", path, nil, function(j, err)
    if not j then cb(nil, err, nil); return end
    cb(j.value or {}, nil, j["@odata.nextLink"])
  end)
end

function M.list_channel_messages_until_read(team_id, channel_id, last_read_iso, cb)
  local all = {}
  local max_pages = 10
  local function fetch_page(path, page_num)
    graph_request_async("read", "GET", path, nil, function(j, err)
      if not j then
        if #all > 0 then cb(all, nil, nil) else cb(nil, err, nil) end
        return
      end
      local page_msgs = j.value or {}
      for _, m in ipairs(page_msgs) do table.insert(all, m) end
      local nextLink = j["@odata.nextLink"]
      if not nextLink or nextLink == "" or page_num >= max_pages then cb(all, nil, nextLink); return end
      if last_read_iso and last_read_iso ~= "" then
        local reached = false
        for _, m in ipairs(page_msgs) do local ct = m.createdDateTime; if ct and ct <= last_read_iso then reached = true; break end end
        if reached then
          local nextPath = nextLink:gsub("^https://graph.microsoft.com/v1.0", "")
          graph_request_async("read", "GET", nextPath, nil, function(j2, _) if j2 and j2.value then for _, m in ipairs(j2.value) do table.insert(all, m) end cb(all, nil, j2["@odata.nextLink"]) else cb(all, nil, nextLink) end end)
          return
        end
      end
      local nextPath = nextLink:gsub("^https://graph.microsoft.com/v1.0", "")
      fetch_page(nextPath, page_num + 1)
    end)
  end
  fetch_page(string.format("/chats/%s/messages?$top=5", channel_id), 1)
end

function M.mark_chat_read(chat_id, cb)
  get_user_identity(function(user_id, tenant_id, err)
    if not user_id then cb(nil, err or "could not retrieve user identity"); return end
    local body = { user = { id = user_id, tenantId = tenant_id } }
    graph_request_async("read", "POST", "/chats/" .. chat_id .. "/markChatReadForUser", body, function(j, err2)
      if j or not err2 then cb(j or {}, nil); return end
      cb(nil, err2)
    end)
  end)
end

local function escape_html(str)
  return str:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

local function expand_image_path(path)
  if path:sub(1,1) == "~" then
    local home = os.getenv("HOME") or ""
    return home .. path:sub(2)
  end
  return path
end

local function read_image_base64(filepath)
  local full_path = expand_image_path(filepath)
  if vim.fn.filereadable(full_path) ~= 1 then return nil, "file not found" end
  local out = vim.fn.system({"python3", "-c", "import base64,sys; sys.stdout.write(base64.b64encode(open(sys.argv[1],'rb').read()).decode())", full_path})
  if vim.v.shell_error ~= 0 or out == "" then return nil, "base64 encoding failed" end
  return out:gsub("%s+", ""), nil
end

local function markdown_to_teams_html(md)
  if not md or md == "" or md == vim.NIL then return "", {} end

  local hosted_contents = {}
  local images = {}

  -- 1. Match images: ![alt](filepath)
  local text = md:gsub("!%[([^%]]*)%]%(([^%)]+)%)", function(alt, img_path)
    local clean_path = img_path:gsub("^%s+", ""):gsub("%s+$", "")
    local b64, _ = read_image_base64(clean_path)
    if b64 then
      local temp_id = tostring(#hosted_contents + 1)
      local ext = clean_path:match("%.([%w]+)$") or "png"
      ext = ext:lower()
      local mime = "image/png"
      if ext == "jpg" or ext == "jpeg" then mime = "image/jpeg"
      elseif ext == "gif" then mime = "image/gif"
      elseif ext == "webp" then mime = "image/webp"
      end

      table.insert(hosted_contents, {
        ["@microsoft.graph.temporaryId"] = temp_id,
        contentType = mime,
        contentBytes = b64,
      })

      local img_alt = alt ~= "" and escape_html(alt) or ("image." .. ext)
      table.insert(images, string.format('<img src="../hostedContents/%s/$value" alt="%s">', temp_id, img_alt))
      return "\003IMG" .. #images .. "\003"
    end
    return string.format("![%s](%s)", alt, img_path)
  end)

  -- 2. Match multiline code blocks: ```[lang]\n[code]\n```
  local codeblocks = {}
  text = text:gsub("```([%w_-]*)\n?(.-)```", function(lang, code)
    local l = lang:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if l == "bash" or l == "sh" or l == "zsh" or l == "shell" then
      l = "bash"
    elseif l == "json" then
      l = "json"
    elseif l == "html" or l == "xml" then
      l = "html"
    elseif l == "js" or l == "javascript" then
      l = "javascript"
    elseif l == "ts" or l == "typescript" then
      l = "typescript"
    elseif l == "py" or l == "python" then
      l = "python"
    elseif l == "cs" or l == "csharp" then
      l = "csharp"
    elseif l == "sql" then
      l = "sql"
    elseif l == "lua" then
      l = "lua"
    elseif l == "" then
      l = "plaintext"
    end

    local clean_code = escape_html(code:gsub("^\n+", ""):gsub("\n+$", ""))
    clean_code = clean_code:gsub("\n", "<br>")
    table.insert(codeblocks, string.format('<codeblock class="%s"><code>%s</code></codeblock>', l, clean_code))
    return "\001CB" .. #codeblocks .. "\001"
  end)

  -- 3. Inline code: `code`
  local inlines = {}
  text = text:gsub("`([^`\n]+)`", function(code)
    table.insert(inlines, "<code>" .. escape_html(code) .. "</code>")
    return "\002IN" .. #inlines .. "\002"
  end)

  -- 4. Escape normal text
  text = escape_html(text)

  -- 5. Convert newlines to <br>
  text = text:gsub("\n", "<br>")

  -- 6. Restore inline code
  text = text:gsub("\002IN(%d+)\002", function(idx)
    return inlines[tonumber(idx)] or ""
  end)

  -- 7. Restore codeblocks
  text = text:gsub("\001CB(%d+)\001", function(idx)
    return codeblocks[tonumber(idx)] or ""
  end)

  -- 8. Restore image tags
  text = text:gsub("\003IMG(%d+)\003", function(idx)
    return images[tonumber(idx)] or ""
  end)

  return text, hosted_contents
end

function M.send_message(chat_id, content, cb)
  local html_content, hosted_contents = markdown_to_teams_html(content)
  local body = { body = { contentType = "html", content = html_content } }
  if hosted_contents and #hosted_contents > 0 then
    body.hostedContents = hosted_contents
  end
  graph_request_async("send", "POST", string.format("/chats/%s/messages", chat_id), body, function(j, err)
    if not j then cb(nil, err); return end
    cb(j, nil)
  end)
end

function M.mark_chat_unread(chat_id, last_read_time, cb)
  if type(last_read_time) == "function" then
    cb = last_read_time
    last_read_time = nil
  end
  get_user_identity(function(user_id, tenant_id, err)
    if not user_id then cb(nil, err or "could not retrieve user identity"); return end
    local user_obj = {
      id = user_id,
      ["@odata.type"] = "#microsoft.graph.teamworkUserIdentity",
      userIdentityType = "aadUser",
    }
    if tenant_id and tenant_id ~= "" then
      user_obj.tenantId = tenant_id
    end
    local body = { user = user_obj }
    if last_read_time and last_read_time ~= "" then
      body.lastMessageReadDateTime = last_read_time
    end
    graph_request_async("read", "POST", "/chats/" .. chat_id .. "/markChatUnreadForUser", body, function(j, err2)
      if j or not err2 then cb(j or {}, nil); return end
      cb(nil, err2)
    end)
  end)
end

function M.list_users(query, cb)
  local path = "/users?$top=50&$select=id,displayName,mail,userPrincipalName"
  if query and query ~= "" then
    local q_enc = url_encode(query)
    path = "/users?$top=50&$filter=startswith(displayName,'" .. q_enc .. "')%20or%20startswith(mail,'" .. q_enc .. "')%20or%20startswith(userPrincipalName,'" .. q_enc .. "')&$select=id,displayName,mail,userPrincipalName"
  end
  graph_request_async("send", "GET", path, nil, function(j, err)
    if not j then
      -- fallback try with 'read' client
      graph_request_async("read", "GET", path, nil, function(j2, err2)
        if not j2 then cb(nil, err2 or err); return end
        cb(j2.value or {}, nil)
      end)
      return
    end
    cb(j.value or {}, nil)
  end)
end

function M.create_chat(target_user_id, cb)
  get_user_identity(function(my_user_id, _, err)
    if not my_user_id then
      cb(nil, err or "could not get current user id")
      return
    end
    local body = {
      chatType = "oneOnOne",
      members = {
        {
          ["@odata.type"] = "#microsoft.graph.aadUserConversationMember",
          roles = { "owner" },
          ["user@odata.bind"] = "https://graph.microsoft.com/v1.0/users('" .. my_user_id .. "')",
        },
        {
          ["@odata.type"] = "#microsoft.graph.aadUserConversationMember",
          roles = { "owner" },
          ["user@odata.bind"] = "https://graph.microsoft.com/v1.0/users('" .. target_user_id .. "')",
        },
      },
    }
    graph_request_async("send", "POST", "/chats", body, function(j, err2)
      if not j then cb(nil, err2); return end
      cb(j, nil)
    end)
  end)
end

return M
