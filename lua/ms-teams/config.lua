local M = {}

M.defaults = {
  -- single source for storage
  data_dir = vim.fn.stdpath("data") .. "/ms-teams",
  -- unified first-party client: single token for read + write + send + create + mark read/unread
  client = {
    client_id = "a8759234-4b8b-4d94-8c0a-ee1ab73af270",
    redirect_uri = "ms-appx-web://Microsoft.AAD.BrokerPlugin/a8759234-4b8b-4d94-8c0a-ee1ab73af270",
    scope = "offline_access openid profile Chat.Create Chat.ReadWrite ChatMessage.Send User.Read User.ReadBasic.All",
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
