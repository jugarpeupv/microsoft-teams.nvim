local config = require("ms-teams.config")

local M = {}

local function token_path(kind)
  return config.options.data_dir .. "/" .. kind .. ".json"
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
  if vim.v.shell_error ~= 0 then return nil, out end
  local ok, j = pcall(vim.json.decode, out)
  if not ok then return nil, out end
  if j.error then return nil, j.error_description or j.error end
  return j, nil
end

local function refresh_token(client, refresh_token)
  local curl = {
    "curl", "-s", "--max-time", "30", "-X", "POST", "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    "-d", "client_id=" .. client.client_id,
    "-d", "refresh_token=" .. refresh_token,
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
  local client = config.options.clients[kind]
  if not client then return nil, "unknown client " .. kind end
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

function M.login(kind, cb)
  local client = config.options.clients[kind]
  if not client then
    vim.notify("unknown client " .. tostring(kind), vim.log.levels.ERROR)
    if cb then cb(nil) end
    return
  end
  local verifier, challenge = gen_pkce()
  local url = auth_url(client, verifier, challenge)
  vim.fn.jobstart({ "open", url }, { detach = true })
  vim.notify(string.format("ms-teams (%s): browser opened for %s - login and copy URL/code", kind, client.name), vim.log.levels.INFO)
  vim.ui.input({ prompt = string.format("Paste code/URL for %s (%s): ", kind, client.name) }, function(input)
    if not input or input == "" then
      vim.notify("login cancelled", vim.log.levels.WARN)
      if cb then cb(nil) end
      return
    end
    -- extract code= if full URL pasted
    local code = input:match("[?&]code=([^&]+)")
    if code then
      code = vim.fn.system({ "python3", "-c", "import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1]))", code }):gsub("%s+", "")
    else
      code = vim.fn.system({ "python3", "-c", "import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1].strip()))", input }):gsub("%s+", "")
      if code == "" then code = input:gsub("%s+", "") end
    end
    code = code:gsub("%s+", "")
    if code == "" then
      vim.notify("no code extracted", vim.log.levels.ERROR)
      if cb then cb(nil) end
      return
    end
    vim.notify(string.format("Exchanging code for %s token...", kind), vim.log.levels.INFO)
    local tok, err = exchange_code(client, code, verifier)
    if not tok then
      vim.notify(string.format("ms-teams %s login failed: %s", kind, err), vim.log.levels.ERROR)
      if cb then cb(nil) end
      return
    end
    tok.expires_at = os.time() + (tok.expires_in or 3599)
    write_json(token_path(kind), tok)
    vim.notify(string.format("ms-teams %s login ok, scopes: %s", kind, tok.scope or ""), vim.log.levels.INFO)
    if cb then cb(tok) end
  end)
end

function M.login_all(cb)
  -- need 2 logins sequentially: read then send (second is quick via SSO cookie)
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
