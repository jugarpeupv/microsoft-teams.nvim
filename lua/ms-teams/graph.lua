local config = require("ms-teams.config")
local auth = require("ms-teams.auth")

local M = {}

local function graph_request(kind, method, path, body)
  local token, err = auth.get_token(kind)
  if not token then return nil, err end
  local url = config.options.graph_base .. path
  local curl = { "curl", "-s", "--max-time", "30", "-X", method, url, "-H", "Authorization: Bearer " .. token, "-H", "Content-Type: application/json" }
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
  local token, err = auth.get_token(kind)
  if not token then
    vim.schedule(function() cb(nil, err) end)
    return
  end
  local url = config.options.graph_base .. path
  local cmd = { "curl", "-s", "--max-time", "30", "-X", method, url, "-H", "Authorization: Bearer " .. token, "-H", "Content-Type: application/json" }
  if body then
    table.insert(cmd, "-d")
    table.insert(cmd, vim.json.encode(body))
  end
  vim.system(cmd, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        cb(nil, obj.stderr ~= "" and obj.stderr or obj.stdout)
        return
      end
      local ok, j = pcall(vim.json.decode, obj.stdout)
      if not ok then cb(nil, obj.stdout); return end
      if j.error then cb(nil, j.error.message or vim.inspect(j.error)); return end
      cb(j, nil)
    end)
  end)
end

function M.list_chats(cb, opts)
  opts = opts or {}
  local top = opts.top or config.options.chat_top
  local do_all = opts.all or false
  local expand = "$expand=members,lastMessagePreview"
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
  local _ = auth.get_token("read")
  local path = config.options.data_dir .. "/read.json"
  if vim.fn.filereadable(path) == 1 then
    local data = vim.fn.readfile(path)
    local ok, j = pcall(vim.json.decode, table.concat(data, "\n"))
    local tid, oid
    if ok and j and j.access_token then
      local parts = vim.split(j.access_token, ".", { plain = true })
      if #parts >= 2 then
        local b64 = parts[2]:gsub("-", "+"):gsub("_", "/")
        local pad = #b64 % 4
        if pad > 0 then b64 = b64 .. string.rep("=", 4 - pad) end
        local ok2, js = pcall(vim.json.decode, vim.fn.system({ "python3", "-c", "import base64,sys,json;print(base64.b64decode(sys.argv[1]).decode())", b64 }))
        if ok2 and js then
          local ok3, pj = pcall(vim.json.decode, js)
          if ok3 and pj and pj.tid and (pj.oid or pj.sub) then
            cb(pj.oid or pj.sub, pj.tid, nil)
            return
          end
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

function M.send_message(chat_id, content, cb)
  local body = { body = { contentType = "text", content = content } }
  graph_request_async("send", "POST", string.format("/chats/%s/messages", chat_id), body, function(j, err)
    if not j then cb(nil, err); return end
    cb(j, nil)
  end)
end

function M.mark_chat_unread(chat_id, cb)
  get_user_identity(function(user_id, tenant_id, err)
    if not user_id then cb(nil, err or "could not retrieve user identity"); return end
    local body = { user = { id = user_id, tenantId = tenant_id } }
    graph_request_async("read", "POST", "/chats/" .. chat_id .. "/markChatUnreadForUser", body, function(j, err2)
      if j or not err2 then cb(j or {}, nil); return end
      cb(nil, err2)
    end)
  end)
end

return M
