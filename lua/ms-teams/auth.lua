local config = require("ms-teams.config")

local M = {}

local function auth_log(msg, lvl)
  local cfg = config.options or {}
  if not (cfg.debug or cfg.auth_debug) then return end
  lvl = lvl or vim.log.levels.DEBUG
  local line = string.format("[%s] %s", os.date("%H:%M:%S"), msg)
  pcall(vim.notify, "[ms-teams auth] " .. msg, lvl)
  local path = (cfg.data_dir or vim.fn.stdpath("data") .. "/ms-teams") .. "/auth_debug.log"
  pcall(function()
    local f = io.open(path, "a")
    if f then f:write(line .. "\n"); f:close() end
  end)
end

local function get_client(_)
  return config.options.client or (config.options.clients and (config.options.clients.read or config.options.clients.send))
end

local function token_path(_)
  return config.options.data_dir .. "/token.json"
end

local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local data = vim.fn.readfile(path)
  if #data == 0 then return nil end
  local ok, j = pcall(vim.json.decode, table.concat(data, "\n"))
  if ok then return j end
  return nil
end

local function write_json(path, tbl)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(tbl) }, path)
  -- restrict permissions like pbpaste tokens
  vim.fn.system({ "chmod", "600", path })
end

local function gen_pkce()
  local verifier = vim.fn.system({ "python3", "-c", "import secrets; print(secrets.token_urlsafe(64))" }):gsub("%s+", "")
  local challenge = vim.fn.system({ "python3", "-c", "import hashlib,base64,sys; print(base64.urlsafe_b64encode(hashlib.sha256(sys.argv[1].encode()).digest()).decode().rstrip('='))", verifier }):gsub("%s+", "")
  if challenge == "" then
    challenge = vim.fn.system({ "bash", "-c", string.format("echo -n %s | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=' | tr -d '\\n'", vim.fn.shellescape(verifier)) }):gsub("%s+", "")
  end
  return verifier, challenge
end

local function auth_url(client, verifier, challenge)
  local scope_enc = vim.fn.system({ "python3", "-c", "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))", client.scope }):gsub("%s+", "")
  local redirect_enc = vim.fn.system({ "python3", "-c", "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))", client.redirect_uri }):gsub("%s+", "")
  return string.format(
    "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=%s&response_type=code&redirect_uri=%s&scope=%s&code_challenge=%s&code_challenge_method=S256&prompt=select_account",
    client.client_id, redirect_enc, scope_enc, challenge
  )
end

local function exchange_code(client, code, verifier)
  auth_log("exchange_code start code_len=" .. #code, vim.log.levels.DEBUG)
  local curl = {
    "curl", "-s", "--max-time", "30", "-X", "POST", "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    "-d", "client_id=" .. client.client_id,
    "-d", "code=" .. code,
    "-d", "redirect_uri=" .. client.redirect_uri,
    "-d", "grant_type=authorization_code",
    "-d", "code_verifier=" .. verifier,
    "-d", "scope=" .. client.scope,
  }
  if client.is_spa then
    table.insert(curl, 3, "-H")
    table.insert(curl, 4, "Origin: " .. (client.origin or "https://mesh.df.onecdn.static.microsoft"))
    table.insert(curl, 5, "-H")
    table.insert(curl, 6, "Referer: " .. client.redirect_uri)
  end
  local out = vim.fn.system(curl)
  auth_log("exchange curl exit=" .. vim.v.shell_error .. " out_len=" .. #out .. " out=" .. out:sub(1,200), vim.log.levels.DEBUG)
  if vim.v.shell_error ~= 0 then return nil, out end
  local ok, j = pcall(vim.json.decode, out)
  if not ok then return nil, out end
  if j.error then return nil, j.error_description or j.error end
  return j, nil
end

local function refresh_token(client, refresh_tok)
  local curl = {
    "curl", "-s", "--max-time", "30", "-X", "POST", "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    "-d", "client_id=" .. client.client_id,
    "-d", "refresh_token=" .. refresh_tok,
    "-d", "grant_type=refresh_token",
    "-d", "scope=" .. client.scope,
  }
  if client.is_spa then
    table.insert(curl, 3, "-H")
    table.insert(curl, 4, "Origin: " .. (client.origin or "https://mesh.df.onecdn.static.microsoft"))
    table.insert(curl, 5, "-H")
    table.insert(curl, 6, "Referer: " .. client.redirect_uri)
  end
  local out = vim.fn.system(curl)
  if vim.v.shell_error ~= 0 then return nil, out end
  local ok, j = pcall(vim.json.decode, out)
  if not ok then return nil, out end
  if j.error then return nil, j.error_description or j.error end
  return j, nil
end

function M.get_token(kind)
  local client = get_client(kind)
  if not client then return nil, "no OAuth client configured" end
  local path = token_path(kind)
  local tok = read_json(path)
  if not tok or not tok.access_token then return nil, "no token, run :MSTeamsLogin" end
  -- check expiry (expires_in -> expires_at)
  local now = os.time()
  if tok.expires_at and tok.expires_at - 60 > now then
    return tok.access_token, nil
  end
  if tok.refresh_token then
    local new_tok, err = refresh_token(client, tok.refresh_token)
    if new_tok then
      new_tok.expires_at = os.time() + (new_tok.expires_in or 3599)
      -- keep old refresh if not returned
      if not new_tok.refresh_token then new_tok.refresh_token = tok.refresh_token end
      write_json(path, new_tok)
      return new_tok.access_token, nil
    end
    return nil, "refresh failed: " .. (err or "unknown") .. " - run :MSTeamsLogin"
  end
  return nil, "token expired, no refresh_token - run :MSTeamsLogin"
end

local is_logging_in = false

function M.ensure_token_async(kind, cb)
  local client = get_client(kind)
  if not client then
    cb(nil, "no OAuth client configured")
    return
  end
  local tok, err = M.get_token(kind)
  if tok then
    cb(tok, nil)
    return
  end

  -- If already logging in or login poll active, don't trigger another login
  if is_logging_in or active_login_poll then
    cb(nil, "login already in progress")
    return
  end

  is_logging_in = true
  local client_name = client.name or "ms-teams"
  vim.notify(string.format("ms-teams (%s): token expired / sign-in required, opening login...", client_name), vim.log.levels.WARN)

  M.login(kind, function(new_tok)
    is_logging_in = false
    if new_tok and new_tok.access_token then
      cb(new_tok.access_token, nil)
    else
      cb(nil, "login failed or cancelled: " .. (err or "no token"))
    end
  end)
end

local function extract_code_from_string(input)
  if not input or input == "" then return nil end
  local raw = input:gsub("^%s+", ""):gsub("%s+$", "")
  local code = raw:match("[?&#]code=([^&]+)")
  if code then
    local clean = vim.fn.system({ "python3", "-c", "import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1]))", code }):gsub("%s+", "")
    return clean ~= "" and clean or nil
  end
  -- If direct code pasted: must be long enough and match standard MS OAuth code prefix
  if #raw >= 30 and not raw:find("%s") then
    if raw:sub(1,2) == "0." or raw:sub(1,2) == "M." or raw:sub(1,5) == "OAAAB" then
      local clean = vim.fn.system({ "python3", "-c", "import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1].strip()))", raw }):gsub("%s+", "")
      return clean ~= "" and clean or nil
    end
  end
  return nil
end

local active_login_poll = nil

function M.cancel_login()
  if active_login_poll then
    if active_login_poll.timer then
      pcall(function()
        active_login_poll.timer:stop()
        active_login_poll.timer:close()
      end)
    end
    if active_login_poll.cb then
      active_login_poll.cb(nil)
    end
    active_login_poll = nil
    vim.notify("ms-teams: login cancelled", vim.log.levels.INFO)
  end
end

function M.login(kind, cb)
  local client = get_client(kind)
  if not client then
    vim.notify("unknown client " .. tostring(kind), vim.log.levels.ERROR)
    if cb then cb(nil) end
    return
  end

  -- Cancel any previous pending login
  if active_login_poll then
    M.cancel_login()
  end

  local verifier, challenge = gen_pkce()
  auth_log(string.format("login start kind=%s client=%s redirect=%s scope=%s", kind, client.client_id, client.redirect_uri, client.scope), vim.log.levels.INFO)
  auth_log("pkce verifier=" .. verifier:sub(1,10) .. "... challenge=" .. challenge:sub(1,10) .. "...", vim.log.levels.DEBUG)
  local url = auth_url(client, verifier, challenge)
  auth_log("auth_url=" .. url, vim.log.levels.DEBUG)
  local jid = vim.fn.jobstart({ "open", url }, { detach = true })
  auth_log("jobstart open jid=" .. tostring(jid), vim.log.levels.DEBUG)

  vim.notify(
    string.format(
      "ms-teams: Browser opened. Log in and click Continue.\nNeovim will automatically capture the authorization code.",
      kind
    ),
    vim.log.levels.INFO
  )

  local initial_clip = vim.fn.getreg("+") or ""
  local timer = (vim.uv or vim.loop).new_timer()
  local start_time = os.time()
  local done = false

  local function finish(tok, err)
    if done then return end
    done = true
    if timer and not timer:is_closing() then
      pcall(function() timer:stop(); timer:close() end)
    end
    active_login_poll = nil
    if tok then
      tok.expires_at = os.time() + (tok.expires_in or 3599)
      write_json(token_path(kind), tok)
      vim.notify(string.format("ms-teams %s login ok! (scopes: %s)", kind, tok.scope or ""), vim.log.levels.INFO)
      if cb then cb(tok) end
    else
      if err then
        vim.notify(string.format("ms-teams %s login failed: %s", kind, err), vim.log.levels.ERROR)
      end
      if cb then cb(nil) end
    end
  end

  local function process_input_code(raw_input)
    auth_log("process_input_code raw_len=" .. #raw_input .. " raw=" .. raw_input:sub(1,80), vim.log.levels.DEBUG)
    local code = extract_code_from_string(raw_input)
    if not code then auth_log("extract_code failed", vim.log.levels.DEBUG); return false end
    auth_log("code extracted len=" .. #code .. " prefix=" .. code:sub(1,10) .. "...", vim.log.levels.INFO)
    vim.notify(string.format("ms-teams (%s): Code detected, exchanging token...", kind), vim.log.levels.INFO)
    local tok, err = exchange_code(client, code, verifier)
    if not tok then
      auth_log("exchange_code failed: " .. tostring(err), vim.log.levels.ERROR)
      finish(nil, err)
      return true
    end
    auth_log("exchange_code ok scope=" .. (tok.scope or ""), vim.log.levels.INFO)
    finish(tok, nil)
    return true
  end

  -- Clean previous auth_code.txt if any
  local auth_code_file = config.options.data_dir .. "/auth_code.txt"
  pcall(vim.fn.delete, auth_code_file)

  active_login_poll = {
    kind = kind,
    timer = timer,
    cb = cb,
    process_code = process_input_code,
  }

  -- Poll clipboard & auth_code.txt asynchronously every 300ms without blocking Neovim
  local poll_n = 0
  timer:start(0, 300, vim.schedule_wrap(function()
    if done then return end
    poll_n = poll_n + 1
    if poll_n % 20 == 0 then auth_log(string.format("poll tick %d elapsed=%ds", poll_n, os.time()-start_time), vim.log.levels.DEBUG) end
    -- Timeout after 5 minutes
    if os.time() - start_time > 300 then
      auth_log("login timeout 5m", vim.log.levels.WARN)
      vim.notify(string.format("ms-teams (%s): Login timed out (5m)", kind), vim.log.levels.WARN)
      finish(nil, "timeout")
      return
    end

    -- 1. Check auth_code.txt (written directly by MSTeamsAuthHandler.app)
    if vim.fn.filereadable(auth_code_file) == 1 then
      auth_log("auth_code.txt readable", vim.log.levels.DEBUG)
      local lines = vim.fn.readfile(auth_code_file)
      pcall(vim.fn.delete, auth_code_file)
      if #lines > 0 and lines[1] ~= "" then
        auth_log("auth_code.txt content len=" .. #lines[1], vim.log.levels.DEBUG)
        local matched = extract_code_from_string(lines[1])
        if matched then
          auth_log("auth_code.txt matched code len=" .. #matched, vim.log.levels.INFO)
          process_input_code(lines[1])
          return
        else
          auth_log("auth_code.txt no code extracted", vim.log.levels.DEBUG)
        end
      end
    end

    -- 2. Check clipboard
    local clip = vim.fn.getreg("+") or ""
    if clip ~= "" and clip ~= initial_clip then
      if poll_n % 20 == 0 then auth_log("clip changed len=" .. #clip .. " clip=" .. clip:sub(1,60), vim.log.levels.DEBUG) end
      local matched_code = extract_code_from_string(clip)
      if matched_code then
        auth_log("clip matched", vim.log.levels.INFO)
        process_input_code(clip)
      end
    end
  end))
end

function M.submit_code(raw_input)
  if not active_login_poll or not active_login_poll.process_code then
    vim.notify("no login currently waiting for code. Run :MSTeamsLogin first.", vim.log.levels.WARN)
    return
  end
  local ok = active_login_poll.process_code(raw_input)
  if not ok then
    vim.notify("could not extract OAuth code from input. Paste the full URL from the browser.", vim.log.levels.ERROR)
  end
end

function M.login_all(cb)
  if config.options.client then
    -- Unified client: single login!
    M.login("unified", function(tok)
      if cb then cb(tok ~= nil) end
    end)
    return
  end
  -- Dual client fallback:
  M.login("read", function(tok1)
    if not tok1 then
      vim.notify("read login failed, abort", vim.log.levels.ERROR)
      if cb then cb(false) end
      return
    end
    vim.notify("read token ok, now login for send (ChatMessage.Send) - second browser window will open, just click account (no password)", vim.log.levels.INFO)
    vim.defer_fn(function()
      M.login("send", function(tok2)
        if not tok2 then
          vim.notify("send login failed - read-only mode still works", vim.log.levels.WARN)
          if cb then cb(false) end
          return
        end
        if cb then cb(true) end
      end)
    end, 800)
  end)
end

function M.status()
  if config.options.client then
    local tok = read_json(token_path())
    local function fmt(t)
      if not t then return "missing - :MSTeamsLogin" end
      local exp = t.expires_at and os.date("%Y-%m-%d %H:%M:%S", t.expires_at) or "unknown"
      return string.format("scope=%s\nexpires=%s", t.scope or "?", exp)
    end
    vim.notify(string.format("ms-teams token (unified):\n%s", fmt(tok)), vim.log.levels.INFO)
    return { token = tok }
  end
  local r = read_json(token_path("read"))
  local s = read_json(token_path("send"))
  local function fmt(tok)
    if not tok then return "missing - :MSTeamsLogin" end
    local exp = tok.expires_at and os.date("%Y-%m-%d %H:%M:%S", tok.expires_at) or "unknown"
    return string.format("scope=%s expires=%s", tok.scope or "?", exp)
  end
  vim.notify(string.format("ms-teams read: %s\nsend: %s", fmt(r), fmt(s)), vim.log.levels.INFO)
  return { read = r, send = s }
end

return M
