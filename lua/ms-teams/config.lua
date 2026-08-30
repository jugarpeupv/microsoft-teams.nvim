local M = {}

M.defaults = {
  -- single source for storage
  data_dir = vim.fn.stdpath("data") .. "/ms-teams",
  -- two first-party clients: read (Chat.Read) + send (ChatMessage.Send)
  -- change to own Entra ID app for write+read single token if admin consent granted
  clients = {
    read = {
      client_id = "eea619ad-603a-4b03-a386-860fcc7410d1", -- Microsoft Mesh, pre-consented Chat.ReadWrite (SPA, needs Origin)
      redirect_uri = "https://mesh.df.onecdn.static.microsoft/AuthEnd",
      scope = "offline_access openid profile Chat.ReadWrite",
      name = "ms-teams-read",
      is_spa = true,
      origin = "https://mesh.df.onecdn.static.microsoft",
    },
    send = {
      client_id = "1fec8e78-bce4-4aaf-ab1b-5451cc387264", -- Microsoft Teams, pre-consented ChatMessage.Send
      redirect_uri = "https://login.microsoftonline.com/common/oauth2/nativeclient",
      scope = "offline_access openid profile ChatMessage.Send",
      name = "ms-teams-send",
    },
    -- fallback read-only (if Mesh SPA blocked, use SalesInsights Chat.Read)
    read_fallback = {
      client_id = "b20d0d3a-dc90-485b-ad11-6031e769e221",
      redirect_uri = "https://login.microsoftonline.com/common/oauth2/nativeclient",
      scope = "offline_access openid profile Chat.Read",
      name = "ms-teams-read-fallback",
    },
  },
  graph_base = "https://graph.microsoft.com/v1.0",
  -- Teams: 50 chats, 50 messages per page, scroll to load more
  chat_top = 50,
  chat_search_top = 500,
  message_top = 50,
  -- date display for messages, e.g. Madrid HH:MM DD/MM/YYYY (Europe/Madrid UTC+2 summer, UTC+1 winter)
  date_format = "%H:%M %d/%m/%Y",
  timezone = "Europe/Madrid", -- nil = local, "UTC", or IANA like "Europe/Madrid"
  -- watch: polling while nvim is open (works even if focus is on Chrome)
  watch = {
    enabled = false, -- set true to autostart on setup()
    interval_ms = 60000, -- 60s (min 10s, clamped to avoid Graph throttling)
    limit = 100, -- how many chats to fetch per poll (pagination)
    notifier = "auto", -- "auto" | "terminal-notifier" | "notify-send" | false (vim.notify only)
    sound = "default", -- terminal-notifier -sound, false to disable
    vim_notify = true, -- also vim.notify inside nvim
    notify_self = true, -- preview doesn't contain sender, so keep true
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
