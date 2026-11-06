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
  if j.error then
    local code = j.error.code and ("[" .. tostring(j.error.code) .. "] ") or ""
    local detail = (j.error.message and j.error.message ~= "") and j.error.message or vim.inspect(j.error)
    return nil, code .. detail
  end
  return j, nil
end

local function graph_request_async(kind, method, path, body, cb, extra_headers, attempt)
  auth.ensure_token_async(kind, function(token, err)
    if not token then
      vim.schedule(function() cb(nil, err) end)
      return
    end
    local url = config.options.graph_base .. path
    local cmd = { "curl", "-s", "--max-time", "60", "-X", method, url, "-H", "Authorization: Bearer " .. token, "-H", "Content-Type: application/json" }
    if extra_headers then
      for k, v in pairs(extra_headers) do
        table.insert(cmd, "-H")
        table.insert(cmd, k .. ": " .. v)
      end
    end
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
          -- exit 28 = curl --max-time timeout: transient, callers already get
          -- the error via cb and the next poll retries; don't spam ERROR
          if obj.code ~= 28 then
            vim.notify("ms-teams graph_request_async: " .. errmsg, vim.log.levels.ERROR)
          end
          cb(nil, errmsg)
          return
        end
        local ok, j = pcall(vim.json.decode, obj.stdout)
        if not ok then
          if (not obj.stdout or obj.stdout == "" or vim.trim(obj.stdout) == "") and obj.code == 0 then
            cb({}, nil)
            return
          end
          cb(nil, obj.stdout)
          return
        end
        if j.error then
          local code = j.error.code and ("[" .. tostring(j.error.code) .. "] ") or ""
          local detail = (j.error.message and j.error.message ~= "") and j.error.message or vim.inspect(j.error)
          local emsg = code .. detail
          -- If token was revoked/invalidated on Graph side, clear access_token expiry and trigger auth
          if emsg:find("InvalidAuthenticationToken") or emsg:find("CompactToken") or emsg:find("Lifetime validation failed") then
            -- retry ONCE after re-acquiring the token; without the cap this
            -- recursed forever (refresh storm at ~1Hz when /me 401'd)
            if (attempt or 0) < 1 then
              auth.ensure_token_async(kind, function(new_tok, err_login)
                if new_tok then
                  graph_request_async(kind, method, path, body, cb, extra_headers, (attempt or 0) + 1)
                else
                  cb(nil, emsg)
                end
              end)
              return
            end
            cb(nil, emsg)
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
        graph_request_async("read","GET","/chats/48:notes?$expand=members,lastMessagePreview",nil,function(n,e)
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
      graph_request_async("read","GET","/chats/48:notes?$expand=members,lastMessagePreview",nil,function(n,e)
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

-- newest `top` messages, for live polling of open 1:1 chats
function M.list_messages_top(chat_id, top, cb)
  top = math.max(1, math.min(tonumber(top) or 20, 50))
  local path = string.format("/chats/%s/messages?$top=%d", chat_id, top)
  graph_request_async("read", "GET", path, nil, function(j, err)
    if not j then cb(nil, err); return end
    cb(j.value or {}, nil)
  end)
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
  graph_request_async("read", "GET", "/chats/" .. chat_id .. "?$expand=members,lastMessagePreview", nil, function(j, err)
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

function M.get_channel_members(team_id, channel_id, cb)
  local all = {}
  local function fetch(path, pages)
    graph_request_async("read", "GET", path, nil, function(j, err)
      if not j then
        if pages == 0 then cb(nil, err) else cb({ id = channel_id, members = all }, nil) end
        return
      end
      for _, m in ipairs(j.value or {}) do table.insert(all, m) end
      local nxt = j["@odata.nextLink"]
      if nxt and pages < 8 then
        fetch(nxt:gsub("^https://graph%.microsoft%.com/v1%.0", ""), pages + 1)
      else
        cb({ id = channel_id, members = all }, nil)
      end
    end)
  end
  fetch("/teams/" .. team_id .. "/channels/" .. channel_id .. "/members", 0)
end

-- cb(name, err): name found; err non-nil = failure (caller owns cooldown/
-- pacing; retrying while throttled only extends the penalty); both nil =
-- user does not exist (memoize as unknown)
function M.get_user_name(user_id, cb)
  graph_request_async("read", "GET", "/users/" .. user_id .. "?$select=id,displayName", nil, function(j, err)
    if j and j.displayName and j.displayName ~= "" then cb(j.displayName, nil); return end
    if err and err:find("ResourceNotFound") then cb(nil, nil); return end
    cb(nil, err or "no displayName")
  end)
end

-- full profile for the user detail buffer: names/contact/job data. Cached in
-- memory and on disk: directory lookups are throttled easily, and a profile
-- fetched once should stay visible across sessions/429 windows.
local user_profile_cache = {}
local user_profile_inflight = {}
local PROFILE_TTL = 7 * 24 * 3600
local user_profiles_disk = nil

local function profile_store()
  if user_profiles_disk == nil then
    local ok, j = pcall(require("ms-teams.cache").load, "user_profiles")
    user_profiles_disk = (ok and type(j) == "table") and j or {}
  end
  return user_profiles_disk
end

-- last known profile (bounded by PROFILE_TTL); nil when never fetched
function M.get_cached_profile(user_id)
  if not user_id then return nil end
  if user_profile_cache[user_id] then return user_profile_cache[user_id] end
  local st = profile_store()[user_id]
  if type(st) == "table" and type(st.profile) == "table"
      and (os.time() - (st.ts or 0) < PROFILE_TTL) then
    user_profile_cache[user_id] = st.profile
    return st.profile
  end
  return nil
end

local function profile_save(user_id, j)
  user_profile_cache[user_id] = j
  local st = profile_store()
  st[user_id] = { ts = os.time(), profile = j }
  pcall(require("ms-teams.cache").save, "user_profiles", st)
end

-- opts: { force = true } bypasses the cache (manual refresh)
function M.get_user_profile(user_id, cb, opts)
  opts = opts or {}
  if not user_id or user_id == "" then cb(nil, "no user id"); return end
  if not opts.force then
    local hit = M.get_cached_profile(user_id)
    if hit then cb(hit, nil); return end
  end
  -- coalesce concurrent opens of the same user into a single request
  if user_profile_inflight[user_id] then
    table.insert(user_profile_inflight[user_id], cb)
    return
  end
  user_profile_inflight[user_id] = { cb }
  local function resolve(p, err)
    local waiters = user_profile_inflight[user_id]
    user_profile_inflight[user_id] = nil
    for _, w in ipairs(waiters or {}) do
      vim.schedule(function() w(p, err) end)
    end
  end
  local attempt = 0
  local sel = table.concat({
    "id", "displayName", "mail", "userPrincipalName", "jobTitle", "department",
    "companyName", "officeLocation", "mobilePhone", "businessPhones",
    "preferredLanguage", "city", "country", "accountEnabled", "createdDateTime",
  }, ",")
  local function fetch()
    graph_request_async("read", "GET", "/users/" .. user_id .. "?$select=" .. sel, nil, function(j, err)
      if not j then
        -- /users has its own throttle budget; one short retry covers bursts
        if err and (err:find("TooManyRequests") or err:find("429")) and attempt < 1 then
          attempt = attempt + 1
          vim.defer_fn(fetch, 1500)
          return
        end
        -- keep the last known profile visible even if the refresh failed
        local st = profile_store()[user_id]
        local stale = type(st) == "table" and type(st.profile) == "table" and st.profile or nil
        resolve(stale, err)
        return
      end
      profile_save(user_id, j)
      resolve(j, nil)
    end)
  end
  fetch()
end

-- profile photos: binary download cached under stdpath("cache")/avatars and
-- revalidated with the photo etag, so reopening a user is a no-op. 404 (no
-- photo) is a normal answer and memoized for AVATAR_TTL.
local AVATAR_TTL = 7 * 24 * 3600
local avatar_meta_cache = nil

local function not_nil(v)
  if v == nil or v == vim.NIL then return nil end
  return v
end

local function avatar_meta()
  if avatar_meta_cache == nil then
    local ok, m = pcall(require("ms-teams.cache").load, "avatars")
    avatar_meta_cache = (ok and type(m) == "table") and m or {}
  end
  return avatar_meta_cache
end

local function avatar_save_meta()
  pcall(require("ms-teams.cache").save, "avatars", avatar_meta_cache or {})
end

function M.avatar_dir()
  local dir = vim.fn.stdpath("cache") .. "/ms-teams/avatars"
  vim.fn.mkdir(dir, "p")
  return dir
end

-- cb(path, meta, err): path = cached jpg; path nil + err nil = user has no photo
local avatar_inflight = {}
function M.get_user_photo(user_id, cb)
  if not user_id or user_id == "" then cb(nil, nil, "no user id"); return end
  local dir = M.avatar_dir()
  local path = dir .. "/" .. user_id:gsub("[^%w%-_]", "_") .. ".jpg"
  local meta = avatar_meta()
  local ent = meta[user_id]
  if ent and (os.time() - (ent.ts or 0) < AVATAR_TTL) then
    if ent.none then cb(nil, ent, nil); return end
    if vim.fn.filereadable(path) == 1 then cb(path, ent, nil); return end
  end
  -- coalesce concurrent opens of the same user into a single download
  if avatar_inflight[user_id] then
    table.insert(avatar_inflight[user_id], cb)
    return
  end
  avatar_inflight[user_id] = { cb }
  local function resolve(p, m, e)
    local waiters = avatar_inflight[user_id]
    avatar_inflight[user_id] = nil
    for _, w in ipairs(waiters or {}) do
      vim.schedule(function() w(p, m, e) end)
    end
  end
  -- metadata first: the etag lets us skip re-downloading unchanged photos
  graph_request_async("read", "GET", "/users/" .. user_id .. "/photo", nil, function(j, err)
    if not j then
      if err and (err:find("ImageNotFound") or err:find("itemNotFound")
          or err:lower():find("not found")) then
        meta[user_id] = { none = true, ts = os.time() }
        avatar_save_meta()
        resolve(nil, meta[user_id], nil)
        return
      end
      resolve(nil, nil, err)
      return
    end
    local etag = not_nil(j["@odata.mediaEtag"]) or not_nil(j.etag)
    -- no-photo accounts may answer 200 with the 1x1 gif placeholder
    if not_nil(j.id) == "1x1" or (not_nil(j.width) == 1 and not_nil(j.height) == 1) then
      meta[user_id] = { none = true, ts = os.time() }
      avatar_save_meta()
      resolve(nil, meta[user_id], nil)
      return
    end
    if etag and ent and ent.etag == etag and vim.fn.filereadable(path) == 1 then
      meta[user_id] = { ts = os.time(), etag = etag, ct = ent.ct }
      avatar_save_meta()
      resolve(path, meta[user_id], nil)
      return
    end
    auth.ensure_token_async("read", function(token, terr)
      if not token then resolve(nil, nil, terr); return end
      local url = config.options.graph_base .. "/users/" .. user_id .. "/photo/$value"
      local tmp = path .. ".tmp"
      local cmd = {"curl","-s","--max-time","60","-o",tmp,"-D","-","-w","\n%{http_code}","-X","GET", url, "-H","Authorization: Bearer "..token}
      vim.system(cmd, {text=true}, function(obj)
        vim.schedule(function()
          local raw = (obj.stdout or ""):gsub("\r\n", "\n")
          local code = raw:match("\n(%d%d%d)%s*$")
          local ct = raw:match("[Cc]ontent%-[Tt]ype:%s*([^\r\n]+)")
          if obj.code ~= 0 then
            pcall(vim.fn.delete, tmp)
            resolve(nil, nil, "curl exit " .. tostring(obj.code))
            return
          end
          if code == "404" then
            pcall(vim.fn.delete, tmp)
            meta[user_id] = { none = true, ts = os.time() }
            avatar_save_meta()
            resolve(nil, meta[user_id], nil)
            return
          end
          if code ~= "200" then
            pcall(vim.fn.delete, tmp)
            resolve(nil, nil, "http " .. tostring(code))
            return
          end
          if vim.fn.filereadable(path) == 1 then pcall(vim.fn.delete, path) end
          pcall(vim.fn.rename, tmp, path)
          meta[user_id] = { ts = os.time(), etag = etag, ct = ct }
          avatar_save_meta()
          resolve(path, meta[user_id], nil)
        end)
      end)
    end)
  end)
end

local me_pending = nil -- single-flight: init setup + watch first poll can miss together
function M.get_me(cb)
  if me_pending then
    table.insert(me_pending, cb)
    return
  end
  me_pending = { cb }
  graph_request_async("read", "GET", "/me?$select=id,displayName,mail", nil, function(j, err)
    local pend = me_pending or {}
    me_pending = nil
    for _, c in ipairs(pend) do
      c(j, err or (not j and "no me" or nil))
    end
  end)
end

local function get_user_identity(cb)
  -- 1. Intentar decodificar directamente del token actual en memoria (sin llamadas extra a Graph)
  local auth = require("ms-teams.auth")
  local token = auth.get_token("read")
  if token and type(token) == "string" then
    local parts = vim.split(token, ".", { plain = true })
    if #parts >= 2 then
      local b64 = parts[2]:gsub("-", "+"):gsub("_", "/")
      local pad = #b64 % 4
      if pad > 0 then b64 = b64 .. string.rep("=", 4 - pad) end
      local ok2, js = pcall(vim.json.decode, vim.fn.system({ "python3", "-c", "import base64,sys;sys.stdout.write(base64.b64decode(sys.argv[1]).decode())", b64 }))
      if ok2 and js and js.tid and (js.oid or js.sub) then
        cb(js.oid or js.sub, js.tid, nil)
        return
      end
    end
  end

  -- 2. Fallback: llamadas API /me y /organization (si davmail está deshabilitado o token opaco)
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

-- channels change rarely: serve them from cache without any network
-- while the map is fresh (plain opens stay paint-cheap and throttle-safe).
-- opts: { force = true } (explicit R refresh skips cache), { ttl = secs }.
local CHANNELS_TTL = 900
local channels_throttle_until = 0
local channels_inflight = {} -- team_id -> {cb, ...} (single-flight)

function M.list_channels(team_id, cb, opts)
  opts = opts or {}
  local cache = require("ms-teams.cache")
  local cached_map = cache.load("teams_channels") or {}
  local cached = cached_map[team_id]
  -- kill-switch for sustained throttling episodes: serve cache, zero network
  -- (explicit R with force still refreshes). Reported stale so empty teams
  -- render the retry hint instead of a bare (0).
  local ch_conf = config.options.channels
  if not opts.force and ch_conf and ch_conf.auto_fetch == false then
    cb(cached or {}, nil, false, true); return
  end
  local fresh = cached_map._ts and (os.time() - cached_map._ts < (opts.ttl or CHANNELS_TTL))
  -- fresh cache for a known team: no network at all. An empty list never
  -- counts as fresh: every team has at least one channel, so [] means a
  -- past failure poisoned the cache and must be refetched, not served.
  local have_cached = cached ~= nil and #cached > 0
  if not opts.force and fresh and have_cached then cb(cached, nil, false); return end
  -- recently throttled: fail fast on stale cache instead of hammering
  if not opts.force and os.time() < channels_throttle_until then cb(cached or {}, nil, false, true); return end
  -- single-flight: coalesce concurrent callers for the same team
  if channels_inflight[team_id] then
    table.insert(channels_inflight[team_id], cb)
    return
  end
  channels_inflight[team_id] = { cb }
  local function resolve(chans, err, fetched, stale)
    local waiters = channels_inflight[team_id]
    channels_inflight[team_id] = nil
    for _, w in ipairs(waiters or {}) do
      vim.schedule(function() w(chans, err, fetched, stale) end)
    end
  end
  auth.ensure_token_async("read", function(token, terr)
    if not token then resolve(nil, terr, false); return end
    local url = config.options.graph_base .. "/teams/" .. team_id .. "/allChannels?$select=id,displayName,description,webUrl,membershipType"
    local cmd = {"curl","-s","--max-time","60","-X","GET", url, "-H","Authorization: Bearer "..token, "-H","Content-Type: application/json", "-w","\n%{http_code}", "-D","-"}
    vim.system(cmd, {text=true}, function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then resolve(nil, "curl exit "..obj.code, false); return end
        local raw = (obj.stdout or ""):gsub("\r\n", "\n")
        local code = raw:match("\n(%d%d%d)%s*$")
        if not code then code = "200" end
        local sep = raw:find("\n\n", 1, true)
        local body = sep and raw:sub(sep + 2) or raw
        body = body:gsub("\n" .. code .. "%s*$", "")
        local throttled = code == "429" or body:find("TooManyRequests") ~= nil
        if throttled then
          -- no retries, ever: Graph keeps logging usage while a client is
          -- throttled, so retrying extends the penalty. Serve stale cache
          -- silently; TTL + pacing + single-flight prevent the next storm.
          channels_throttle_until = os.time() + 120
          if cached then resolve(cached, nil, false, true); return end
        end
        if code ~= "200" then
          local ok, j = pcall(vim.json.decode, body)
          if ok and j and j.error then resolve(nil, j.error.message or vim.inspect(j.error), false); return end
          if body == "" then resolve(cached or {}, nil, false); return end
        end
        local ok, j = pcall(vim.json.decode, body)
        if not ok or not j then resolve(cached or {}, nil, false); return end
        local chans = j.value or {}
        -- update channels_map cache
        local map = cache.load("teams_channels") or {}
        map[team_id] = chans
        pcall(cache.save, "teams_channels", map)
        resolve(chans, nil, true)
      end)
    end)
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

function M.get_token_scopes()
  local token = auth.get_token("read")
  if not token or type(token) ~= "string" then return nil end
  local parts = vim.split(token, ".", { plain = true })
  if #parts < 2 then return nil end
  local b64 = parts[2]:gsub("-", "+"):gsub("_", "/")
  local pad = #b64 % 4
  if pad > 0 then b64 = b64 .. string.rep("=", 4 - pad) end
  local ok, js = pcall(vim.json.decode, vim.fn.system({ "python3", "-c", "import base64,sys;sys.stdout.write(base64.b64decode(sys.argv[1]).decode())", b64 }))
  if not ok or not js then return nil end
  local scopes = {}
  if js.scp and type(js.scp) == "string" then
    for s in js.scp:gmatch("%S+") do table.insert(scopes, s) end
  end
  if js.roles and type(js.roles) == "table" then
    for _, r in ipairs(js.roles) do if r ~= vim.NIL then table.insert(scopes, tostring(r)) end end
  end
  return scopes
end

-- Graph throttling (429 TooManyRequests): worth one retry after backoff
local function is_throttle_err(err)
  if not err then return false end
  local s = tostring(err)
  return s:find("TooManyRequests") ~= nil or s:find("429") ~= nil or s:find("[Tt]hrottl") ~= nil
end

local search_throttle_until = 0

function M.search_chat_messages(chat_id, query, cb, team_id)
  if not chat_id or chat_id == "" then cb(nil, "no chat id"); return end
  if not query or query == "" then cb(nil, "empty query"); return end
  if os.time() < search_throttle_until then
    cb(nil, "[TooManyRequests] search throttled, try again later")
    return
  end
  -- $search is not allowed on /chats/{id}/messages (AllowedQueryOptions error),
  -- so we fetch paginated history and filter client-side with smart-case.
  local function plain_of(m)
    if not m or m == vim.NIL then return "" end
    local parts = {}
    local from_tbl = m.from
    if from_tbl and from_tbl ~= vim.NIL then
      local user_tbl = from_tbl.user
      if user_tbl and user_tbl ~= vim.NIL then
        local fu = user_tbl.displayName
        if fu and fu ~= vim.NIL and fu ~= "" then table.insert(parts, tostring(fu)) end
      end
    end
    local body_tbl = m.body
    if body_tbl and body_tbl ~= vim.NIL then
      local b = body_tbl.content
      if b and b ~= vim.NIL and b ~= "" then
        local body = tostring(b)
        body = body:gsub("<[^>]+>", " "):gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
        body = body:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if body ~= "" then table.insert(parts, body) end
      end
    end
    if m.attachments and type(m.attachments) == "table" then
      for _, a in ipairs(m.attachments) do
        if a ~= vim.NIL and a ~= nil then
          local n = a.name
          if n and n ~= vim.NIL and n ~= "" then table.insert(parts, tostring(n)) end
        end
      end
    end
    return table.concat(parts, " ")
  end
  local function matches_plain(plain, q)
    if not plain or plain == "" then return false end
    local sensitive = q:find("%u") ~= nil
    local hay = sensitive and plain or plain:lower()
    local needle = sensitive and q or q:lower()
    return hay:find(needle, 1, true) ~= nil
  end
  local max_pages = 20 -- up to ~1000 msgs
  local all_matches = {}
  local seen_ids = {}
  local function finish_sorted()
    -- oldest first: results read chronologically, newest at the bottom
    -- (ISO dates sort lexicographically)
    table.sort(all_matches, function(a, b)
      local at = (a.createdDateTime and a.createdDateTime ~= vim.NIL) and tostring(a.createdDateTime) or ""
      local bt = (b.createdDateTime and b.createdDateTime ~= vim.NIL) and tostring(b.createdDateTime) or ""
      return at < bt
    end)
    cb(all_matches, nil)
  end
  local function fetch_page(path, page_num)
    local attempts = 0
    local function attempt()
      attempts = attempts + 1
      graph_request_async("read", "GET", path, nil, function(j, err)
        if not j and is_throttle_err(err) and attempts < 3 then
          if tostring(err):find("TooManyRequests") then search_throttle_until = os.time() + 300 end
          vim.defer_fn(attempt, attempts * 10000)
          return
        end
        if not j then
          -- if we already have matches, return them; otherwise propagate error
          if #all_matches > 0 then finish_sorted() else cb(nil, err) end
          return
        end
        for _, m in ipairs(j.value or {}) do
          -- pages can overlap; dedupe by message id
          local mid = (m ~= vim.NIL and m.id and m.id ~= vim.NIL) and tostring(m.id) or nil
          if m ~= vim.NIL and mid and not seen_ids[mid] and matches_plain(plain_of(m), query) then
            seen_ids[mid] = true
            table.insert(all_matches, m)
          end
        end
        local nl = j["@odata.nextLink"]
        if nl and nl ~= "" and page_num < max_pages then
          local path2 = nl:gsub("^https://graph.microsoft.com/v1.0", "")
          fetch_page(path2, page_num + 1)
        else
          finish_sorted()
        end
      end)
    end
    attempt()
  end
  -- start from most recent page; team channel vs chat uses same paginated endpoint as list_messages
  local start_path
  if team_id and team_id ~= "" then
    start_path = string.format("/chats/%s/messages?$top=50", chat_id)
  else
    start_path = string.format("/chats/%s/messages?$top=50", chat_id)
  end
  fetch_page(start_path, 1)
end

function M.list_chat_tabs(chat_id, cb)
  if not chat_id or chat_id == "" then cb(nil, "no chat id"); return end
  local attempts = 0
  local function attempt()
    attempts = attempts + 1
    graph_request_async("read", "GET", "/chats/" .. chat_id .. "/tabs", nil, function(j, err)
      if not j and is_throttle_err(err) and attempts < 3 then
        vim.defer_fn(attempt, attempts * 10000)
        return
      end
      if not j then cb(nil, err); return end
      cb(j.value or {}, nil)
    end)
  end
  attempt()
end

-- create organization view sharing link for a drive item; returns a
-- /:x:/...?e=... style webUrl that opens without an interactive login
function M.create_sharing_link(drive_id, item_id, cb)
  if not drive_id or drive_id == "" or not item_id or item_id == "" then
    cb(nil, "no drive/item id")
    return
  end
  local attempts = 0
  local function attempt()
    attempts = attempts + 1
    graph_request_async("read", "POST",
      "/drives/" .. drive_id .. "/items/" .. item_id .. "/createLink",
      { type = "view", scope = "organization" },
      function(j, err)
        if not j and is_throttle_err(err) and attempts < 3 then
          vim.defer_fn(attempt, attempts * 10000)
          return
        end
        if not j then cb(nil, err); return end
        local link = (type(j) == "table" and type(j.link) == "table") and j.link or nil
        local web_url = (link and link.webUrl) or j.webUrl or j.shareUrl
        if not web_url or web_url == "" then cb(nil, "no webUrl in createLink response"); return end
        cb(web_url, nil)
      end)
  end
  attempt()
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
