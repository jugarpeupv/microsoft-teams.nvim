local config = require("ms-teams.config")
local M = {}

local timer = nil
local polling = false
local seen = {} -- chat_id -> last preview id or createdDateTime
local initialized = false

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
  if not s or s == "" then return "" end
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
  local body = strip_html(nv(preview.body) or nv(preview.summary) or "")
  if body == "" then body = nv(preview.messageType) or "nuevo mensaje" end
  local from = ""
  -- preview may have from? try to extract displayName from preview if present
  -- fallback: use title as chat name, body as message
  local w = config.options.watch or {}
  local notifier = get_notifier()

  if notifier == "terminal-notifier" then
    local args = { "terminal-notifier", "-title", title, "-message", body, "-group", nv(chat.id) or title }
    if w.sound ~= false then
      table.insert(args, "-sound")
      table.insert(args, w.sound or "default")
    end
    -- on click: focus neovim via activate or execute nvim
    -- use -sender com.apple.Terminal to group; leave default
    local obj = vim.system(args, { text = true }, function() end)
    -- non-blocking, ignore result
    _ = obj
  elseif notifier == "notify-send" then
    vim.system({ "notify-send", title, body }, { text = true }, function() end)
  else
    -- fallback: vim.notify (visible when back in nvim)
    local msg = string.format("%s: %s", title, body)
    vim.schedule(function()
      vim.notify(msg, vim.log.levels.INFO)
    end)
  end

  -- also echo in nvim if option enabled
  if w.vim_notify ~= false then
    vim.schedule(function()
      vim.notify(string.format("Teams: %s — %s", title, body), vim.log.levels.INFO)
    end)
  end
end

local function do_poll()
  if polling then return end
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
          if p then notify(chat, p) end
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
          if p then notify(chat, p) end
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
  local w = config.options.watch or {}
  local interval = w.interval_ms or 60000
  if interval < 10000 then interval = 10000 end -- clamp 10s min to avoid Graph throttling

  local uv = vim.uv or vim.loop
  timer = uv.new_timer()
  -- Poll lo hace vim.schedule_wrap -> corre en main loop aunque el foco esté en Chrome
  -- vim.uv timers siguen disparando mientras el proceso nvim esté vivo (no necesita focus)
  timer:start(0, interval, vim.schedule_wrap(do_poll))

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
