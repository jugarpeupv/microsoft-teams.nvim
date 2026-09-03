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
local function run_auth_cmd()
  local ok, cfg = pcall(require, "ms-teams.config")
  local dav = ok and cfg.options and cfg.options.davmail or {}
  local cmd = dav.auth_cmd or "davmail-token"
  if not cmd or cmd == "" then return false end
  -- debounce: only launch once per 60s
  if auth_cmd_pending and os.time() - auth_cmd_pending < 60 then return true end
  auth_cmd_pending = os.time()
  local job_cmd
  if type(cmd) == "table" then job_cmd = cmd
  else
    -- use zsh -ic to resolve aliases like davmail-token (needs interactive to load ~/.zshrc)
    job_cmd = {"zsh","-ic", cmd}
  end
  vim.notify("ms-teams davmail: token missing or expired, running auth_cmd...", vim.log.levels.WARN)
  pcall(vim.fn.jobstart, job_cmd, {
    pty = true,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          vim.notify("ms-teams: davmail authenticated successfully, re-run command", vim.log.levels.INFO)
        else
          vim.notify("ms-teams: davmail auth_cmd failed (exit " .. code .. ")", vim.log.levels.ERROR)
        end
      end)
    end
  })
  return true
end

function M.load_davmail_token(opts)
  opts = opts or {}
  local token_file = opts.token_file or read_prop("davmail.oauth.tokenFilePath", vim.fn.expand("~/.config/davmail/oauth_tokens.env"))
  local password = opts.password
  if password == nil then password = read_prop("davmail.oauth.password", "") end

  if vim.fn.filereadable(token_file) ~= 1 then
    if run_auth_cmd() then return nil, "no token file - auth_cmd launched, re-run after login" end
    return nil, "no token file"
  end

  local user = (opts.username or read_prop("davmail.username") or "user@example.com"):lower()
  local raw_val = nil
  for _, line in ipairs(vim.fn.readfile(token_file)) do
    local trimmed = vim.trim(line)
    if not trimmed:match("^#") and trimmed:match("=") then
      local k, v = trimmed:match("^([^=]+)=(.*)$")
      if k and vim.trim(k):lower() == user then
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
    if run_auth_cmd() then return nil, "no token for " .. user .. " - auth_cmd launched" end
    return nil, "no token for " .. user
  end

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
      if not ok or not j or not j.access_token then cb(nil, "no access_token "..obj.stdout:sub(1,300)); return end
      local expires_on = os.time() + (tonumber(j.expires_in) or 3600)
      if j.expires_on then expires_on = tonumber(j.expires_on) end
      local tok = {access_token=j.access_token, expires_on=expires_on, refresh_token=j.refresh_token or refresh_token}
      save_access_cache(tok)
      cb(tok.access_token, nil)
    end)
  end)
end

function M.get_access_token(opts, cb)
  opts = opts or {}
  local cached = load_access_cache()
  if cached then cb(cached.access_token, nil); return end
  local refresh, err = M.load_davmail_token(opts)
  if not refresh then cb(nil, err); return end
  refresh_access_token(refresh, opts, cb)
end

function M.get_access_token_sync(opts)
  opts = opts or {}
  local cached = load_access_cache()
  if cached then return cached.access_token end
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
  if not ok or not j or not j.access_token then return nil, out:sub(1,300) end
  local expires_on = os.time() + (tonumber(j.expires_in) or 3600)
  if j.expires_on then expires_on = tonumber(j.expires_on) end
  save_access_cache({access_token=j.access_token, expires_on=expires_on, refresh_token=j.refresh_token or refresh})
  return j.access_token
end

return M
