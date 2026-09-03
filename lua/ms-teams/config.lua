local M = {}

M.defaults = {
  -- single source for storage
  data_dir = vim.fn.stdpath("data") .. "/ms-teams",
  -- davmail reuse: single token governed by davmail (no second device_code)
  -- reads refresh_token from davmail.oauth.tokenFilePath and refreshes via common/oauth2/v2.0/token
  davmail = {
    enabled = true,
    token_file = nil, -- nil -> auto from davmail.oauth.tokenFilePath or ~/.config/davmail/oauth_tokens.env
    username = "user@example.com",
    client_id = "d3590ed6-52b3-4102-aeff-aad2292ab01c",
    tenant_id = "common",
    redirect_uri = "urn:ietf:wg:oauth:2.0:oob",
    fingerprint = "davmailgateway!&",
    password = "", -- for {AES} decrypt; "" when davmail stores plain (password empty at creation)
    auth_cmd = nil, -- nil | string | string[] to run when token file missing, e.g. "davmail-token" alias or {"bash","-c","davmail-token"}
  },
  -- fallback legacy first-party client (used when davmail.enabled=false or file missing)
  client = {
    client_id = "a8759234-4b8b-4d94-8c0a-ee1ab73af270",
    redirect_uri = "ms-appx-web://Microsoft.AAD.BrokerPlugin/a8759234-4b8b-4d94-8c0a-ee1ab73af270",
    scope = "offline_access openid profile ChannelMessage.Send Chat.Create Chat.ReadWrite ChatMessage.Send Contacts.Read email Family.Read Files.ReadWrite Files.ReadWrite.All Group.Read.All Mail.ReadWrite Mail.Send openid People.Read profile ProfilePhoto.Read.All Sites.ReadWrite.All User.Read User.Read.All User.ReadBasic.All",
    name = "ms-teams",
  },
  graph_base = "https://graph.microsoft.com/v1.0",
  -- Teams: 50 chats, 50 messages per page, scroll to load more
  chat_top = 50,
  chat_search_top = 500,
  message_top = 50,
  -- date display for messages, e.g. Madrid HH:MM DD/MM/YYYY (Europe/Madrid UTC+2 summer, UTC+1 winter)
  date_format = "%H:%M %d/%m/%Y",
  timezone = "Europe/Madrid", -- nil = local, "UTC", or IANA like "Europe/Madrid"
  -- highlights: group used for unread chats/messages (defaults to "DiagnosticInfo")
  highlights = {
    unread = "DiagnosticInfo",
  },
  debug = false, -- global debug for auth/graph logs (auth_debug.log)
  auth_debug = false,
  -- watch: polling while nvim is open (works even if focus is on Chrome)
  watch = {
    enabled = false, -- set true to autostart on setup()
    interval_ms = 60000, -- 60s (min 10s, clamped to avoid Graph throttling)
    limit = 100, -- how many chats to fetch per poll (pagination)
    notifier = "auto", -- "auto" | "terminal-notifier" | "notify-send" | false (vim.notify only)
    sound = "default", -- terminal-notifier -sound, false to disable
    vim_notify = true, -- also vim.notify inside nvim
    notify_self = true, -- preview doesn't contain sender, so keep true
    mentions_only = true, -- only notify when you / @Everyone / @Todos are mentioned
    debug = false,
  },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  vim.fn.mkdir(M.options.data_dir, "p")
  return M.options
end

return M
