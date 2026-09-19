-- Reutiliza token DavMail y obtiene Access Token para Microsoft Graph API
local M = {}

local function find_davmail_jar()
  local candidates = {
    "/opt/homebrew/Cellar/davmail/6.8.1/libexec/davmail.jar",
    "/opt/homebrew/share/davmail/davmail.jar",
    "/usr/local/share/davmail/davmail.jar",
    "/usr/share/davmail/davmail.jar",
    "/Applications/DavMail.app/Contents/Java/davmail.jar",
  }
  local brew_glob = vim.fn.glob("/opt/homebrew/Cellar/davmail/*/libexec/davmail.jar", false, true)
  if type(brew_glob) == "table" and #brew_glob > 0 then
    table.insert(candidates, 1, brew_glob[#brew_glob])
  end
  for _, p in ipairs(candidates) do
    if vim.fn.filereadable(p) == 1 then return p end
  end
  return nil
end

local function get_davmail_props()
  local p = vim.fn.expand("~/.davmail.properties")
  if vim.fn.filereadable(p) ~= 1 then p = vim.fn.expand("~/.config/davmail/davmail.properties") end
  if vim.fn.filereadable(p) ~= 1 then p = vim.fn.expand("~/dotfiles/davmail/.davmail.properties") end
  return p
end

local function read_prop(key, default)
  local prop_path = get_davmail_props()
  if vim.fn.filereadable(prop_path) == 1 then
    for _, line in ipairs(vim.fn.readfile(prop_path)) do
      local k, v = line:match("^%s*([^#][^=]*)=(.*)$")
      if k and k:match("^%s*" .. key .. "%s*$") then return v:gsub("^%s+",""):gsub("%s+$","") end
    end
  end
  return default
end

local function decrypt_aes_token(token_file, username, password)
  local jar = find_davmail_jar()
  if not jar then return nil, "davmail.jar not found" end

  password = password or ""
  local java_code = string.format([[
import davmail.Settings;
import davmail.exchange.auth.O365Token;
import java.io.*;
import java.lang.reflect.*;

public class GetDavmailToken {
    public static void main(String[] args) {
        try {
            File propFile = new File("%s");
            if (!propFile.exists()) {
                propFile = new File("%s");
            }
            if (propFile.exists()) {
                FileInputStream fis = new FileInputStream(propFile);
                Settings.load(fis);
                fis.close();
            }
            Settings.setProperty("davmail.oauth.tokenFilePath", "%s");
            Settings.setProperty("davmail.oauth.persistToken", "true");
            
            String tenantId = Settings.getProperty("davmail.oauth.tenantId", "common");
            String clientId = Settings.getProperty("davmail.oauth.clientId", "d3590ed6-52b3-4102-aeff-aad2292ab01c");
            String redirectUri = Settings.getProperty("davmail.oauth.redirectUri", "urn:ietf:wg:oauth:2.0:oob");

            Method loadMethod = O365Token.class.getDeclaredMethod(
                "load", String.class, String.class, String.class, String.class, String.class
            );
            loadMethod.setAccessible(true);
            
            O365Token token = (O365Token) loadMethod.invoke(
                null,
                tenantId,
                clientId,
                redirectUri,
                "%s",
                "%s"
            );
            if (token != null) {
                String rt = token.getRefreshToken();
                if (rt != null && !rt.isEmpty()) {
                    System.out.println("TOKEN_OUTPUT:" + rt);
                    return;
                }
            }
            System.err.println("Failed to obtain token from DavMail store");
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}
]], vim.fn.expand("~/.davmail.properties"), vim.fn.expand("~/dotfiles/davmail/.davmail.properties"), token_file, username, password:gsub('\\', '\\\\'):gsub('"', '\\"'))

  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir, "p")
  local java_file = tmp_dir .. "/GetDavmailToken.java"
  local f = io.open(java_file, "w")
  if not f then return nil, "could not write temp java file" end
  f:write(java_code)
  f:close()

  local compile_cmd = string.format('javac -cp %s -d %s %s 2>&1', vim.fn.shellescape(jar), vim.fn.shellescape(tmp_dir), vim.fn.shellescape(java_file))
  local compile_out = vim.fn.system(compile_cmd)
  if vim.v.shell_error ~= 0 then
    vim.fn.delete(tmp_dir, "rf")
    return nil, "javac failed: " .. compile_out
  end

  local run_cmd = string.format('java -cp %s:%s GetDavmailToken', vim.fn.shellescape(jar), vim.fn.shellescape(tmp_dir))
  local run_out = vim.fn.system(run_cmd)
  vim.fn.delete(tmp_dir, "rf")

  local token = run_out:match("TOKEN_OUTPUT:(%S+)")
  if not token then
    return nil, "could not decrypt davmail token: " .. run_out
  end
  return token, nil
end

local auth_cmd_pending = nil
-- processes WE spawned via run_auth_cmd (jobid -> true); killed on VimLeave
local auth_jobs = {}
-- circuit breaker: consecutive auth_cmd launches without any token success.
-- Stops the respawn loop (missing file + watch poll); re-armed by success
-- or M.reset_auth_breaker() (watch restart).
local auth_launch_count = 0
local auth_breaker_tripped = false

-- max fruitless launches before the breaker silences auto-heal.
-- davmail.auth_max_attempts (default 1): e.g. 1 = single attempt, then quiet.
local function max_attempts()
  local ok, cfg = pcall(require, "ms-teams.config")
  local dav = (ok and cfg.options and cfg.options.davmail) or {}
  local n = tonumber(dav.auth_max_attempts) or 1
  if n < 1 then n = 1 end
  return n
end

local function note_auth_success()
  auth_launch_count = 0
  auth_breaker_tripped = false
end
-- notify-once for missing token state: first failure notifies, repeats are
-- suppressed until success or a different message / 5 min pass
local last_missing_notify_at = 0
local last_missing_msg = nil
local function notify_missing_once(msg)
  local now = os.time()
  if msg ~= last_missing_msg or now - last_missing_notify_at > 300 then
    last_missing_msg = msg
    last_missing_notify_at = now
    vim.notify("ms-teams: " .. msg, vim.log.levels.ERROR)
  end
end
local function reset_missing_notify()
  last_missing_msg = nil
  last_missing_notify_at = 0
end
local function run_auth_cmd(quiet)
  local ok, cfg = pcall(require, "ms-teams.config")
  local dav = ok and cfg.options and cfg.options.davmail or {}
  -- explicit opt-out: auth_cmd = false NEVER auto-launches (nil = default).
  -- NOTE: must check before `or "davmail-token"`, which would swallow false.
  if dav.auth_cmd == false then return false end
  local cmd = dav.auth_cmd or "davmail-token"
  if cmd == nil or cmd == "" then return false end
  -- tripped breaker: stay silent until reset (success / restart)
  if auth_breaker_tripped then return false end
  -- debounce: only launch once per 60s
  if auth_cmd_pending and os.time() - auth_cmd_pending < 60 then return true end
  auth_cmd_pending = os.time()
  local job_cmd
  if type(cmd) == "table" then job_cmd = cmd
  else
    -- use zsh -ic to resolve aliases like davmail-token (needs interactive to load ~/.zshrc)
    job_cmd = {"zsh","-ic", cmd}
  end
  if not quiet then
    vim.notify("ms-teams davmail: token missing or expired, running auth_cmd...", vim.log.levels.WARN)
  end
  local okj, jid = pcall(vim.fn.jobstart, job_cmd, {
    pty = true,
    on_exit = function(id, code)
      auth_jobs[id] = nil
      vim.schedule(function()
        if code == 0 then
          vim.notify("ms-teams: davmail authenticated successfully, refreshing...", vim.log.levels.INFO)
          -- give davmail a moment to flush oauth_tokens.env, then retry pending UI
          vim.defer_fn(function()
            local ok_ui, ui = pcall(require, "ms-teams.ui")
            if ok_ui and ui.refresh_chats_background then
              ui.refresh_chats_background(function() end)
            end
            local ok_w, watch = pcall(require, "ms-teams.watch")
            if ok_w and watch.is_running and watch.is_running() and watch.poll_once then
              watch.poll_once()
            end
          end, 2000)
        else
          vim.notify("ms-teams: davmail auth_cmd failed (exit " .. code .. ")", vim.log.levels.ERROR)
        end
      end)
    end
  })
  if not (okj and jid and jid > 0) then return false end
  auth_jobs[jid] = true
  auth_launch_count = auth_launch_count + 1
  if auth_launch_count >= max_attempts() and not auth_breaker_tripped then
    auth_breaker_tripped = true
    vim.notify(string.format(
      "ms-teams: auth_cmd launched %dx with no token - auto-heal silenced until login succeeds or :MSTeamsWatchRestart",
      auth_launch_count), vim.log.levels.WARN)
  end
  return true
end

function M.reset_auth_breaker()
  auth_launch_count = 0
  auth_breaker_tripped = false
  auth_cmd_pending = nil
end

function M.auth_breaker_status()
  return { tripped = auth_breaker_tripped, launches = auth_launch_count, max = max_attempts() }
end

-- kill auth_cmd processes WE spawned (called on VimLeave so a closed
-- editor never leaves orphan davmail-token/java behind)
function M.stop_pending_auth()
  local n = 0
  for jid, _ in pairs(auth_jobs) do
    pcall(vim.fn.jobstop, jid)
    auth_jobs[jid] = nil
    n = n + 1
  end
  return n
end

local function resolve_token_file(opts)
  opts = opts or {}
  local ok, cfg = pcall(require, "ms-teams.config")
  local dav = (ok and cfg.options and cfg.options.davmail) or {}

  local candidates = {}

  -- 1. Explicit user config in opts or setup
  local explicit = opts.token_file or opts.davmail_token_file or dav.token_file or dav.davmail_token_file
  if explicit and explicit ~= "" then
    table.insert(candidates, { path = vim.fn.expand(explicit), source = "plugin config (davmail.token_file)" })
  end

  -- 2. From .davmail.properties (davmail.oauth.tokenFilePath)
  local prop_path = get_davmail_props()
  if prop_path and vim.fn.filereadable(prop_path) == 1 then
    local prop_val = read_prop("davmail.oauth.tokenFilePath", nil)
    if prop_val and prop_val ~= "" then
      table.insert(candidates, { path = vim.fn.expand(prop_val), source = prop_path .. " [davmail.oauth.tokenFilePath]" })
    end
  end

  -- Check if any candidate exists
  for _, c in ipairs(candidates) do
    if vim.fn.filereadable(c.path) == 1 then
      return c.path, nil
    end
  end

  -- Build error message listing expected paths
  local searched = {}
  for _, c in ipairs(candidates) do
    table.insert(searched, string.format("'%s' (%s)", c.path, c.source))
  end

  local prop_sources = { "~/.davmail.properties", "~/.config/davmail/davmail.properties", "~/dotfiles/davmail/.davmail.properties" }
  local msg
  if #searched > 0 then
    msg = string.format("DavMail token file not found on disk. Checked: [%s]", table.concat(searched, ", "))
  else
    msg = string.format(
      "DavMail token file is not configured. Please set `davmail.token_file` in setup() or configure `davmail.oauth.tokenFilePath` in DavMail properties (searched: %s).",
      table.concat(prop_sources, ", ")
    )
  end

  return nil, msg
end

function M.load_davmail_token(opts)
  opts = opts or {}
  local ok, cfg = pcall(require, "ms-teams.config")
  local dav = (ok and cfg.options and cfg.options.davmail) or {}

  local token_file, resolve_err = resolve_token_file(opts)
  if not token_file then
    notify_missing_once(resolve_err)
    if run_auth_cmd() then
      return nil, resolve_err .. " - auth_cmd launched, re-run after login"
    end
    return nil, resolve_err
  end

  local password = opts.password or dav.password
  if password == nil then password = read_prop("davmail.oauth.password", "") end

  local user = (opts.username or dav.username or read_prop("davmail.username") or ""):lower()
  local raw_val = nil
  for _, line in ipairs(vim.fn.readfile(token_file)) do
    local trimmed = vim.trim(line)
    if not trimmed:match("^#") and trimmed:match("=") then
      local k, v = trimmed:match("^([^=]+)=(.*)$")
      if k and user ~= "" and vim.trim(k):lower() == user then
        raw_val = vim.trim(v)
        break
      end
    end
  end

  if not raw_val or raw_val == "" then
    -- fallback to first entry
    for _, line in ipairs(vim.fn.readfile(token_file)) do
      local trimmed = vim.trim(line)
      if not trimmed:match("^#") and trimmed:match("=") then
        local _, v = trimmed:match("^([^=]+)=(.*)$")
        if v then raw_val = vim.trim(v); break end
      end
    end
  end

  if not raw_val or raw_val == "" then
    local msg = "no token entry found for user '" .. (user ~= "" and user or "<any>") .. "' in " .. token_file
    notify_missing_once(msg)
    if run_auth_cmd() then return nil, msg .. " - auth_cmd launched" end
    return nil, msg
  end

  reset_missing_notify()
  note_auth_success()
  if raw_val:match("^{AES}") then
    return decrypt_aes_token(token_file, user, password)
  else
    return raw_val, nil
  end
end

local access_cache = nil
local access_cache_path = nil
local function get_cache_path()
  if access_cache_path then return access_cache_path end
  local ok, cfg = pcall(require, "ms-teams.config")
  local dir = (ok and cfg.options and cfg.options.data_dir) or vim.fn.stdpath("data") .. "/ms-teams"
  access_cache_path = dir .. "/davmail_access.json"
  return access_cache_path
end

local function load_access_cache()
  if access_cache and access_cache.expires_on and access_cache.expires_on > os.time() + 60 then return access_cache end
  local p = get_cache_path()
  if vim.fn.filereadable(p) == 1 then
    local ok, j = pcall(vim.json.decode, table.concat(vim.fn.readfile(p), "\n"))
    if ok and j and j.access_token and j.expires_on and j.expires_on > os.time() + 60 then
      access_cache = j
      return j
    end
  end
  return nil
end

local function save_access_cache(tok)
  access_cache = tok
  local p = get_cache_path()
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  pcall(vim.fn.writefile, {vim.json.encode(tok)}, p)
  pcall(vim.fn.system, {"chmod","600",p})
end

local function read_current_refresh_token()
  local opts = {}
  local ok, cfg = pcall(require, "ms-teams.config")
  if ok and cfg.options and cfg.options.davmail then opts = cfg.options.davmail end
  local token_file, err = resolve_token_file(opts)
  if not token_file then return nil end
  local user = ((opts.username or cfg.options.davmail.username) or read_prop("davmail.username") or ""):lower()
  for _, line in ipairs(vim.fn.readfile(token_file)) do
    local trimmed = vim.trim(line)
    if not trimmed:match("^#") and trimmed:match("=") then
      local k, v = trimmed:match("^([^=]+)=(.*)$")
      if k and user ~= "" and vim.trim(k):lower() == user then
        local val = vim.trim(v)
        return (val ~= "" and val ~= "") and val or nil
      end
    end
  end
  return nil
end

local function access_cache_stale()
  local cached = load_access_cache()
  if not cached then return true end
  local current_rt = read_current_refresh_token()
  if not current_rt then return false end
  if cached.refresh_token ~= current_rt then
    access_cache = nil
    return true
  end
  return false
end

-- errors meaning the refresh token/session is dead and only an interactive
-- re-login fixes it (e.g. AADSTS50078 MFA expired, expired/revoked grant)
local function is_reauth_needed(err_text)
  if not err_text then return false end
  local s = tostring(err_text):lower()
  return s:find("invalid_grant", 1, true) ~= nil
    or s:find("interaction_required", 1, true) ~= nil
end

local reauth_cooldown_until = 0
local REAUTH_COOLDOWN_S = 600 -- relaunch auth_cmd at most every 10 min for dead sessions

local function clear_access_cache()
  access_cache = nil
  pcall(vim.fn.delete, get_cache_path())
end

-- returns true when err_text indicated a dead session (caller should surface
-- a short re-login message instead of the raw error)
local function handle_dead_session(err_text)
  if not is_reauth_needed(err_text) then return false end
  clear_access_cache()
  local now = os.time()
  if now < reauth_cooldown_until then return true end
  reauth_cooldown_until = now + REAUTH_COOLDOWN_S
  vim.notify("ms-teams: davmail session expired, re-login required - running auth_cmd...", vim.log.levels.WARN)
  run_auth_cmd(true) -- quiet: already notified above
  return true
end

local function refresh_access_token(refresh_token, opts, cb)
  local cfg_ok, cfg = pcall(require, "ms-teams.config")
  local dav = (cfg_ok and cfg.options and cfg.options.davmail) or {}
  local client_id = opts.client_id or dav.client_id or "d3590ed6-52b3-4102-aeff-aad2292ab01c"
  local tenant_id = opts.tenant_id or dav.tenant_id or "common"
  local redirect_uri = opts.redirect_uri or dav.redirect_uri or "urn:ietf:wg:oauth:2.0:oob"
  local token_url = "https://login.microsoftonline.com/"..tenant_id.."/oauth2/v2.0/token"
  local scope = opts.scope or dav.scope or "https://graph.microsoft.com/.default offline_access"

  local curl = {
    "curl", "-s", "--max-time", "30", "-X", "POST", token_url,
    "--data-urlencode", "client_id=" .. client_id,
    "--data-urlencode", "grant_type=refresh_token",
    "--data-urlencode", "refresh_token=" .. refresh_token,
    "--data-urlencode", "redirect_uri=" .. redirect_uri,
    "--data-urlencode", "scope=" .. scope,
  }

  vim.system(curl, {text=true}, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then cb(nil, "curl exit "..obj.code.." "..(obj.stderr or "")); return end
      local ok, j = pcall(vim.json.decode, obj.stdout)
      if not ok or not j or not j.access_token then
        local raw = obj.stdout or ""
        if handle_dead_session(raw) then
          cb(nil, "davmail session expired, re-login required - auth_cmd launched, re-run after login")
        else
          cb(nil, "no access_token "..raw:sub(1,300))
        end
        return
      end
      local expires_on = os.time() + (tonumber(j.expires_in) or 3600)
      if j.expires_on then expires_on = tonumber(j.expires_on) end
      local tok = {access_token=j.access_token, expires_on=expires_on, refresh_token=j.refresh_token or refresh_token}
      save_access_cache(tok)
      reauth_cooldown_until = 0 -- session healthy again
      note_auth_success()
      cb(tok.access_token, nil)
    end)
  end)
end

function M.get_access_token(opts, cb)
  opts = opts or {}
  local cached = load_access_cache()
  if cached and not access_cache_stale() then cb(cached.access_token, nil); return end
  local refresh, err = M.load_davmail_token(opts)
  if not refresh then cb(nil, err); return end
  refresh_access_token(refresh, opts, cb)
end

function M.get_access_token_sync(opts)
  opts = opts or {}
  local cached = load_access_cache()
  if cached and not access_cache_stale() then return cached.access_token end
  local refresh, err = M.load_davmail_token(opts)
  if not refresh then return nil, err end
  local cfg_ok, cfg = pcall(require, "ms-teams.config")
  local dav = (cfg_ok and cfg.options and cfg.options.davmail) or {}
  local client_id = opts.client_id or dav.client_id or "d3590ed6-52b3-4102-aeff-aad2292ab01c"
  local tenant_id = opts.tenant_id or dav.tenant_id or "common"
  local redirect_uri = opts.redirect_uri or dav.redirect_uri or "urn:ietf:wg:oauth:2.0:oob"
  local token_url = "https://login.microsoftonline.com/"..tenant_id.."/oauth2/v2.0/token"
  local scope = opts.scope or dav.scope or "https://graph.microsoft.com/.default offline_access"

  local curl = {
    "curl", "-s", "--max-time", "30", "-X", "POST", token_url,
    "--data-urlencode", "client_id=" .. client_id,
    "--data-urlencode", "grant_type=refresh_token",
    "--data-urlencode", "refresh_token=" .. refresh,
    "--data-urlencode", "redirect_uri=" .. redirect_uri,
    "--data-urlencode", "scope=" .. scope,
  }
  local out = vim.fn.system(curl)
  if vim.v.shell_error ~= 0 then return nil, out end
  local ok, j = pcall(vim.json.decode, out)
  if not ok or not j or not j.access_token then
    if handle_dead_session(out) then
      return nil, "davmail session expired, re-login required - auth_cmd launched, re-run after login"
    end
    return nil, out:sub(1,300)
  end
  local expires_on = os.time() + (tonumber(j.expires_in) or 3600)
  if j.expires_on then expires_on = tonumber(j.expires_on) end
  save_access_cache({access_token=j.access_token, expires_on=expires_on, refresh_token=j.refresh_token or refresh})
  reauth_cooldown_until = 0 -- session healthy again
  note_auth_success()
  return j.access_token
end

return M
