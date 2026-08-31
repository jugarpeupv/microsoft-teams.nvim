local config = require("ms-teams.config")
local M = {}

local timer = nil
local polling = false
local seen = {} -- chat_id -> last preview id or createdDateTime
local initialized = false
local me_cache = nil
local me_fetching = false
local lock_owner = false

local function lock_path()
  return (config.options.data_dir or vim.fn.stdpath("data") .. "/ms-teams") .. "/watch.lock"
end

local function is_pid_alive(pid)
  if not pid or pid <= 0 then return false end
  local ok, uv = pcall(require, "vim.uv")
  if not ok then uv = vim.loop end
  if uv and uv.kill then
    local ok2, err = pcall(uv.kill, pid, 0)
    if ok2 then return true end
    if err and tostring(err):find("ESRCH") then return false end
    return false
  end
  -- fallback: no kill support, assume alive if recent
  return true
end

local function read_lock()
  local p = lock_path()
  if vim.fn.filereadable(p) ~= 1 then return nil end
  local ok, data = pcall(vim.fn.readfile, p)
  if not ok or not data or #data == 0 then return nil end
  local ok2, j = pcall(vim.json.decode, table.concat(data, "\n"))
  if ok2 then return j end
  return nil
end

local function is_locked()
  local j = read_lock()
  if not j or not j.pid then return false, nil end
  local pid = tonumber(j.pid)
  if not pid then return false, nil end
  if pid == vim.fn.getpid() then return false, nil end
  if is_pid_alive(pid) then
    local age = os.time() - (tonumber(j.started_at) or 0)
    local interval = (config.options.watch and config.options.watch.interval_ms or 60000) / 1000
    if age < interval * 5 then
      return true, j
    end
  end
  return false, j
end

local function acquire_lock()
  local p = lock_path()
  local data = { pid = vim.fn.getpid(), started_at = os.time() }
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(p, ":h"), "p")
  pcall(vim.fn.writefile, { vim.json.encode(data) }, p)
  lock_owner = true
end

local function release_lock_if_owner()
  if not lock_owner then return end
  local j = read_lock()
  if j and tonumber(j.pid) == vim.fn.getpid() then
    pcall(vim.fn.delete, lock_path())
  end
  lock_owner = false
end

local function nv(v)
  if v == vim.NIL then return nil end
  return v
end

local function format_chat(chat)
  local topic = nv(chat.topic)
  if topic and topic ~= "" then return topic end
  if nv(chat.chatType) == "oneOnOne" then
    local members = nv(chat.members)
    if members and type(members) == "table" then
      for _, m in ipairs(members) do
        if m ~= vim.NIL then
          local name = nv(m.displayName)
          -- avoid hardcoding own name; just pick first non-empty
          if name and name ~= "" then
            -- try to skip self if we can detect: keep heuristic of 2 members pick the other
            -- without self detection, return first; caller will show something
            return name
          end
        end
      end
    end
    return "oneOnOne"
  end
  return nv(chat.chatType) or "chat"
end

local function strip_html(s)
  if type(s) ~= "string" or s == "" then return "" end
  s = s:gsub("<[^>]+>", ""):gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if #s > 200 then s = s:sub(1, 197) .. "..." end
  return s
end

local function get_preview(chat)
  local p = nv(chat.lastMessagePreview)
  if not p then return nil end
  return p
end

local function preview_id(chat)
  local p = get_preview(chat)
  if not p then return nil end
  -- prefer id, fallback to createdDateTime
  local id = nv(p.id) or nv(chat.id) .. (nv(p.createdDateTime) or "")
  local ct = nv(p.createdDateTime) or ""
  -- combine to avoid collisions on same timestamp
  return (id or "") .. "|" .. ct
end

local function has_unread(chat)
  local vp = nv(chat.viewpoint)
  local lr = vp and nv(vp.lastMessageReadDateTime)
  if not lr then return false end
  local p = get_preview(chat)
  local lu = p and nv(p.createdDateTime) or nv(chat.lastUpdatedDateTime)
  if not lu then return false end
  return lu > lr
end

local function is_mentioned(preview)
  if not config.options.watch.mentions_only then return true end
  if not preview then return false end
  local raw = nv(preview.body)
  if type(raw) == "table" then raw = nv(raw.content) end
  raw = raw or nv(preview.summary) or ""
  local low = type(raw) == "string" and raw:lower() or ""
  if low:find("everyone",1,true) or low:find("todos",1,true) or low:find("@channel",1,true) or low:find("@general",1,true) then
    return true
  end
  if me_cache and me_cache.displayName and low:find(me_cache.displayName:lower(),1,true) then
    return true
  end
  local mentions = nv(preview.mentions)
  if mentions and type(mentions)=="table" then
    for _, m in ipairs(mentions) do
      if m ~= vim.NIL then
        local mid = nv(m.id) or (nv(m.mentioned) and nv(nv(m.mentioned).id))
        if mid and me_cache and mid == me_cache.id then return true end
        local mname = nv(m.displayName)
        if mname and me_cache and mname == me_cache.displayName then return true end
      end
    end
  end
  return false
end

local function get_notifier()
  local w = config.options.watch or {}
  if w.notifier == false then return nil end
  if w.notifier and w.notifier ~= "auto" and w.notifier ~= "terminal-notifier" then
    return w.notifier
  end
  if vim.fn.executable("terminal-notifier") == 1 then
    return "terminal-notifier"
  end
  if vim.fn.executable("notify-send") == 1 then
    return "notify-send"
  end
  return nil
end

local function notify(chat, preview)
  local title = format_chat(chat)
  local raw = nv(preview.body)
  if type(raw) == "table" then raw = nv(raw.content) end
  local body = strip_html(raw or nv(preview.summary) or "")
  if body == "" then body = nv(preview.messageType) or "nuevo mensaje" end
  local sender = nil
  local pf = nv(preview.from)
  if pf then
    local pu = nv(pf.user) or pf
    sender = nv(pu.displayName) or nv(pf.displayName)
  end
  if not sender or sender == "" then
    local fp = nv(preview.fromUser) or nv(preview.sender)
    if fp then sender = nv(fp.displayName) or (type(fp)=="string" and fp or nil) end
  end
  if sender and sender ~= "" then body = sender .. ": " .. body end
  local is_meeting = nv(chat.chatType) == "meeting"
  local joinUrl = nv(chat.webUrl) or nv(chat.onlineMeetingUrl)
  if is_meeting and joinUrl and joinUrl ~= "" then
    body = body .. " — Join: " .. joinUrl
  end
  local w = config.options.watch or {}
  local notifier = get_notifier()

  local function do_notify(url)
    if notifier == "terminal-notifier" then
      local args = { "terminal-notifier", "-title", title, "-message", body, "-group", nv(chat.id) or title }
      if url and url ~= "" then
        table.insert(args, "-open")
        table.insert(args, url)
      end
      if w.sound ~= false then
        table.insert(args, "-sound")
        table.insert(args, w.sound or "default")
      end
      local obj = vim.system(args, { text = true }, function() end)
      _ = obj
    elseif notifier == "notify-send" then
      vim.system({ "notify-send", title, body }, { text = true }, function() end)
    else
      local msg = string.format("%s: %s", title, body)
      vim.schedule(function()
        vim.notify(msg, vim.log.levels.INFO)
      end)
    end
    if w.vim_notify ~= false then
      vim.schedule(function()
        vim.notify(string.format("Teams: %s — %s", title, body), vim.log.levels.INFO)
      end)
    end
  end

  if is_meeting and not joinUrl then
    local graph = require("ms-teams.graph")
    graph.get_chat(nv(chat.id), function(full, _)
      local u = full and (nv(full.webUrl) or nv(full.onlineMeetingUrl)) or nil
      if u and u ~= "" then body = body .. " — Join: " .. u end
      do_notify(u)
    end)
    return
  end
  do_notify(joinUrl)
end

local function do_poll()
  if polling then return end
  local w0 = config.options.watch or {}
  if w0.mentions_only and not me_cache and not me_fetching then
    me_fetching = true
    require("ms-teams.graph").get_me(function(j, _)
      if j then me_cache = j end
      me_fetching = false
      do_poll()
    end)
    return
  end
  local auth = require("ms-teams.auth")
  -- Don't trigger background watch polling if user hasn't logged in yet
  local tok = auth.get_token("read")
  if not tok then
    return
  end
  polling = true
  local graph = require("ms-teams.graph")
  local cache = require("ms-teams.cache")
  local w = config.options.watch or {}
  local limit = w.limit or 100
  local top = w.top or config.options.chat_top or 50

  graph.list_chats(function(chats, err)
    polling = false
    if err then
      if w.debug then vim.schedule(function() vim.notify("MSTeams watch poll failed: " .. err, vim.log.levels.DEBUG) end) end
      return
    end
    if not chats or #chats == 0 then return end

    -- update cache every poll so :MSTeamsChats is instant + reflects new messages
    -- uses same key as ui.lua: cache.save("chats",{chats=...}) in cache.lua:23
    cache.save("chats", { chats = chats })

    if not initialized then
      -- first poll: seed seen without notifying to avoid spam on startup
      for _, chat in ipairs(chats) do
        if chat ~= vim.NIL and nv(chat.id) then
          local pid = preview_id(chat)
          if pid then seen[nv(chat.id)] = pid end
        end
      end
      initialized = true
      if w.debug then
        vim.schedule(function() vim.notify(string.format("MSTeams watch iniciado (%d chats)", #chats), vim.log.levels.INFO) end)
      end
      return
    end

    for _, chat in ipairs(chats) do
      if chat == vim.NIL then goto continue end
      local cid = nv(chat.id)
      if not cid then goto continue end
      local pid = preview_id(chat)
      if not pid then goto continue end
      local prev = seen[cid]
      if prev == nil then
        -- new chat apareció
        seen[cid] = pid
        if has_unread(chat) then
          local p = get_preview(chat)
          if p and is_mentioned(p) then notify(chat, p) end
        end
      elseif prev ~= pid then
        seen[cid] = pid
        -- sólo notificar si realmente es unread y no es nuestro propio mensaje si se desea filtrar
        if has_unread(chat) then
          -- opcional: filtrar mensajes propios si we can detect sender
          -- preview doesn't contain full from, but we can check if viewpoint changed? para v1 no filtramos
          if w.notify_self == false then
            -- heuristic: if lastMessagePreview from self, lastMessagePreview is still > lr but we sent it
            -- sin from en preview, no podemos filtrar fiable -> notificar igual; usuario puede activar notify_self=true si quiere
          end
          local p = get_preview(chat)
          if p and is_mentioned(p) then notify(chat, p) end
        end
      end
      ::continue::
    end
  end, { all = true, limit = limit, top = top })
end

function M.start(opts)
  opts = opts or {}
  -- allow override interval for this start
  if opts.interval_ms then config.options.watch.interval_ms = opts.interval_ms end
  if timer then
    vim.notify("MSTeams watch ya activo", vim.log.levels.INFO)
    return timer
  end
  local locked, info = is_locked()
  if locked then
    vim.notify(string.format("MSTeams watch ya activo en PID %s (hace %ds) — no se inicia segundo timer", info.pid, os.time() - (info.started_at or os.time())), vim.log.levels.WARN)
    return nil
  end
  local w = config.options.watch or {}
  local interval = w.interval_ms or 60000
  if interval < 10000 then interval = 10000 end -- clamp 10s min to avoid Graph throttling

  local uv = vim.uv or vim.loop
  timer = uv.new_timer()
  -- Poll lo hace vim.schedule_wrap -> corre en main loop aunque el foco esté en Chrome
  -- vim.uv timers siguen disparando mientras el proceso nvim esté vivo (no necesita focus)
  timer:start(0, interval, vim.schedule_wrap(do_poll))
  acquire_lock()

  vim.notify(string.format("MSTeams watch iniciado (cada %ds) — notifier: %s", interval / 1000, get_notifier() or "vim.notify"), vim.log.levels.INFO)
  return timer
end

function M.stop()
  if not timer then
    vim.notify("MSTeams watch no activo", vim.log.levels.WARN)
    return
  end
  timer:stop()
  timer:close()
  timer = nil
  polling = false
  release_lock_if_owner()
  vim.notify("MSTeams watch detenido", vim.log.levels.INFO)
end

function M.restart()
  if timer then M.stop() end
  -- reset seen so next start no spam, but keep initialized false to reseed
  seen = {}
  initialized = false
  M.start()
end

function M.status()
  local on = timer ~= nil
  local msg = on and string.format("watch activo (cada %ds) notifier=%s", (config.options.watch.interval_ms or 60000)/1000, get_notifier() or "vim.notify")
    or "watch inactivo"
  vim.notify("MSTeams " .. msg, vim.log.levels.INFO)
  return on
end

function M.is_running()
  return timer ~= nil
end

-- for manual trigger without waiting interval
function M.poll_once()
  do_poll()
  vim.notify("MSTeams watch: poll manual disparado", vim.log.levels.INFO)
end

-- reset internal seen (útil tras :MSTeamsChats)
function M.reset_seen()
  seen = {}
  initialized = false
end

return M
