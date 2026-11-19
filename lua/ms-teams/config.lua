local M = {}

-- Configuration types. These annotations power completion and hover in
-- `require("ms-teams").setup({...})` for LuaLS/EmmyLua users.
---@class MsTeams.DavmailConfig
---@field enabled? boolean Reuse the DavMail refresh token.
---@field token_file? string Path to DavMail's oauth_tokens.env.
---@field username? string DavMail username / email.
---@field client_id? string OAuth client id used for the refresh.
---@field tenant_id? string Tenant id ("common" by default).
---@field redirect_uri? string OAuth redirect URI.
---@field fingerprint? string DavMail token fingerprint.
---@field password? string Password for {AES} tokens.
---@field auth_cmd? string|string[]|false Command to obtain a token, or false to disable auto-launch.
---@field auth_max_attempts? integer Fruitless auto-launch attempts before going quiet.

---@class MsTeams.ClientConfig
---@field client_id? string
---@field redirect_uri? string
---@field scope? string
---@field name? string

---@class MsTeams.HighlightsConfig
---@field unread? string Highlight group for unread rows.
---@field meeting_confirmed? string Highlight group for accepted meetings.

---@class MsTeams.ChatTypeIcons
---@field meeting? string
---@field oneOnOne? string
---@field groupChat? string
---@field channel? string
---@field default? string

---@class MsTeams.IconsConfig
---@field enabled? boolean
---@field chatType? MsTeams.ChatTypeIcons
---@field keycap_style? "circled"|"nerd"
---@field keycap_icons? table<string, string>

---@class MsTeams.KeymapsCommon
---@field open? string|false
---@field open_vsplit? string|false
---@field open_split? string|false

---@class MsTeams.KeymapsChatList
---@field open? string|false
---@field open_split? string|false
---@field open_vsplit? string|false
---@field search? string|false
---@field help? string|false
---@field toggle_unread? string|false
---@field toggle_meeting? string|false
---@field toggle_limit? string|false
---@field refresh? string|false
---@field hide? string|false
---@field mark_read? string|false
---@field mark_unread? string|false
---@field user_detail? string|false
---@field close? string|false

---@class MsTeams.KeymapsFinder
---@field open? string|false
---@field open_split? string|false
---@field open_vsplit? string|false
---@field toggle_unread? string|false
---@field mark_read? string|false
---@field mark_unread? string|false
---@field quickfix? string|false
---@field quickfix_all? string|false
---@field user_detail? string|false

---@class MsTeams.KeymapsChatDetail
---@field jump? string|false
---@field reply? string|false
---@field participants? string|false
---@field help? string|false
---@field search? string|false
---@field open_link? string|false
---@field refresh? string|false
---@field load_older? string|false
---@field mark_read? string|false
---@field mark_unread? string|false
---@field reactions_split? string|false
---@field reactions_vsplit? string|false
---@field user_detail? string|false
---@field close? string|false

---@class MsTeams.KeymapsUserDetail
---@field open_photo? string|false
---@field refresh? string|false
---@field help? string|false
---@field close? string|false

---@class MsTeams.KeymapsChatSearch
---@field search? string|false
---@field jump? string|false
---@field jump_focus? string|false
---@field quickfix? string|false
---@field help? string|false
---@field close? string|false

---@class MsTeams.KeymapsTeams
---@field open? string|false
---@field open_split? string|false
---@field open_vsplit? string|false
---@field search? string|false
---@field help? string|false
---@field refresh? string|false
---@field close? string|false

---@class MsTeams.KeymapsSchedule
---@field week? string|false
---@field new? string|false
---@field next? string|false
---@field prev? string|false
---@field date? string|false
---@field current? string|false
---@field help? string|false
---@field refresh? string|false
---@field close? string|false

---@class MsTeams.KeymapsScheduleWeek
---@field day? string|false
---@field new? string|false
---@field next? string|false
---@field prev? string|false
---@field date? string|false
---@field current? string|false
---@field help? string|false
---@field refresh? string|false
---@field close? string|false

---@class MsTeams.KeymapsNewMeeting
---@field save? string|false
---@field help? string|false
---@field close? string|false

---@class MsTeams.KeymapsMeetingDetail
---@field open_url? string|false
---@field copy_url? string|false
---@field accept? string|false
---@field decline? string|false
---@field tentative? string|false
---@field refresh? string|false
---@field delete? string|false
---@field help? string|false
---@field close? string|false

---@class MsTeams.KeymapsConfig
---@field common? MsTeams.KeymapsCommon
---@field chat_list? MsTeams.KeymapsChatList
---@field msteams_finder? MsTeams.KeymapsFinder
---@field chat_detail? MsTeams.KeymapsChatDetail
---@field user_detail? MsTeams.KeymapsUserDetail
---@field chat_search? MsTeams.KeymapsChatSearch
---@field teams? MsTeams.KeymapsTeams
---@field schedule? MsTeams.KeymapsSchedule
---@field schedule_week? MsTeams.KeymapsScheduleWeek
---@field new_meeting? MsTeams.KeymapsNewMeeting
---@field meeting_detail? MsTeams.KeymapsMeetingDetail

---@class MsTeams.LiveRefreshConfig
---@field enabled? boolean
---@field interval_ms? integer
---@field top? integer
---@field only_visible? boolean
---@field lock? boolean

---@class MsTeams.WatchConfig
---@field enabled? boolean
---@field interval_ms? integer
---@field limit? integer
---@field notifier? string|false
---@field sound? string|false
---@field vim_notify? boolean
---@field notify_self? boolean
---@field mentions_only? boolean
---@field debug? boolean

---@class MsTeams.ScheduleConfig
---@field hide_cancelled? boolean

---@class MsTeams.ChannelsConfig
---@field unread_max_age_days? integer
---@field auto_fetch? boolean

---@class MsTeams.Config
---@field data_dir? string
---@field davmail? MsTeams.DavmailConfig
---@field client? MsTeams.ClientConfig
---@field graph_base? string
---@field chat_top? integer
---@field chat_search_top? integer
---@field message_top? integer
---@field date_format? string
---@field timezone? string
---@field highlights? MsTeams.HighlightsConfig
---@field icons? MsTeams.IconsConfig
---@field debug? boolean
---@field auth_debug? boolean
---@field open_cmd? string[]
---@field keymaps? MsTeams.KeymapsConfig
---@field refresh_one_to_one_chats_opts? MsTeams.LiveRefreshConfig
---@field watch? MsTeams.WatchConfig
---@field schedule? MsTeams.ScheduleConfig
---@field channels? MsTeams.ChannelsConfig

---@type MsTeams.Config
M.defaults = {
  -- single source for storage
  data_dir = vim.fn.stdpath("data") .. "/ms-teams",
  -- davmail reuse: single token governed by davmail (no second device_code)
  -- reads refresh_token from davmail.oauth.tokenFilePath and refreshes via common/oauth2/v2.0/token
  davmail = {
    enabled = true,
    token_file = nil, -- path to DavMail oauth tokens file (or auto-resolved via davmail.oauth.tokenFilePath in ~/.davmail.properties)
    username = nil, -- username / email in DavMail
    client_id = "d3590ed6-52b3-4102-aeff-aad2292ab01c",
    tenant_id = "common",
    redirect_uri = "urn:ietf:wg:oauth:2.0:oob",
    fingerprint = "davmailgateway!&",
    password = "", -- for {AES} decrypt; "" when davmail stores plain (password empty at creation)
    auth_cmd = nil, -- nil = default "davmail-token" alias | string | string[] to run when token file missing, e.g. {"bash","-c","davmail-token"} | false = NEVER auto-launch (silent, no respawn loop)
    auth_max_attempts = 1, -- fruitless auth_cmd launches before auto-heal silences itself (1 = single attempt, then quiet until login succeeds or :MSTeamsWatchRestart)
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
    -- accepted meetings in the day/week schedule (unaccepted use default)
    meeting_confirmed = "DiagnosticOk",
  },
   -- icons for chats: type (emoji defaults, configurable)
   icons = {
    enabled = true,
    chatType = {
      meeting = "󰊻",
      oneOnOne = "",
      groupChat = "",
      channel = "",
      default = "󰭘",
    },
    -- Keycap reactions: "circled" (universal, any font) or "nerd"
    -- (md-numeric-N-box, requires a Nerd Font). Alternatively set
    -- keycap_icons to a custom per-digit map (missing digits stay raw).
    keycap_style = "circled",
    keycap_icons = nil,
  },
  debug = false, -- global debug for auth/graph logs (auth_debug.log)
  auth_debug = false,
  -- command used to open URLs in the browser (gx). nil = default (vim.ui.open).
  -- e.g. pin a Chrome profile that holds the M365 session:
  -- open_cmd = {"open", "-a", "Google Chrome", "--args", "--profile-directory=Profile 3"}
  open_cmd = nil,
  -- Per-buffer keymaps. Override any action; nil/false disables the mapping.
  -- Defaults are deep-merged, so you only need to set what changes.
  keymaps = {
    -- shared by list buffers: open the item in current window / vsplit / split
    common = {
      open = "<CR>",
      open_vsplit = "<C-v>",
      open_split = "<C-s>",
    },
    -- chat list buffer (:MSTeamsChats)
    chat_list = {
      open = "<CR>",
      open_split = "<C-s>",
      open_vsplit = "<C-v>",
      search = "g/",
      help = "g?",
      toggle_unread = "U",
      toggle_meeting = "M",
      toggle_limit = "gS",
      refresh = "R",
      hide = "<C-x>",
      mark_read = "mr",
      mark_unread = "mu",
      user_detail = "mp", -- 1:1 chat under cursor
      close = "q",
    },
    -- :MSTeamsFind telescope picker
    msteams_finder = {
      open = "<CR>",
      open_split = "<C-s>",
      open_vsplit = "<C-v>",
      toggle_unread = "<C-g>",
      mark_read = "<C-e>",
      mark_unread = "<C-b>",
      quickfix = "<C-q>",
      quickfix_all = "<M-q>",
      user_detail = "<C-i>",
    },
    chat_detail = {
      jump = "<CR>",
      reply = "S",
      participants = "gp",
      help = "g?",
      search = "F",
      open_link = "gx",
      refresh = "R",
      load_older = "gR",
      mark_read = "mr",
      mark_unread = "mu",
      reactions_split = "<C-s>",
      reactions_vsplit = "<C-v>",
      user_detail = "mp", -- 1:1 chats only
      close = "q",
    },
    user_detail = {
      open_photo = "gx",
      refresh = "R",
      help = "g?",
      close = "q",
    },
    -- chat search results buffer (F in a chat)
    chat_search = {
      search = "F",
      jump = "<CR>",
      jump_focus = "<S-CR>",
      quickfix = "<C-q>",
      help = "g?",
      close = "q",
    },
    -- :MSTeamsTeams teams/channels list
    teams = {
      open = "<CR>",
      open_split = "<C-s>",
      open_vsplit = "<C-v>",
      search = "g/",
      help = "g?",
      refresh = "R",
      close = "q",
    },
    schedule = {
      week = "<Tab>",
      new = "<C-n>",
      next = "K",
      prev = "J",
      date = "gd",
      current = "go",
      help = "g?",
      refresh = "R",
      close = "q",
    },
    schedule_week = {
      day = "<S-Tab>",
      new = "<C-n>",
      next = "K",
      prev = "J",
      date = "gd",
      current = "go",
      help = "g?",
      refresh = "R",
      close = "q",
    },
    new_meeting = {
      save = "<C-s>",
      help = "g?",
      close = "q",
    },
    meeting_detail = {
      open_url = "gx",
      copy_url = "yu",
      accept = "A",
      decline = "D",
      tentative = "T",
      refresh = "R",
      delete = "X",
      help = "g?",
      close = "q",
    },
  },
  -- Keep open 1:1 chat buffers up to date. Graph has no push for chat
  -- messages (change notifications need a public HTTPS endpoint), so the
  -- visible 1:1 buffer is polled. interval_ms is clamped to >= 10000ms to
  -- stay gentle with throttling; groups/channels are never polled.
  refresh_one_to_one_chats_opts = {
    enabled = true,
    interval_ms = 10000,
    top = 20,           -- newest messages merged when something changed
    only_visible = true, -- skip while the buffer is not on screen
    lock = true,        -- one Neovim instance at a time polls a given chat
  },
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
  -- Today's meetings (:MSTeamsSchedule). hide_cancelled=false shows all,
  -- including all-day and already-finished events (marked in the list).
  schedule = {
    hide_cancelled = false,
  },
  -- channels carry no server-side read state; unread is inferred from the
  -- latest message vs local reference (mr override or messages cache). When
  -- there is no local reference at all, only messages newer than this are
  -- treated as unread (avoids flagging years-old messages as unread)
  channels = {
    unread_max_age_days = 30,
    -- false = serve channel lists from cache only: no allChannels traffic
    -- on opens (useful during sustained throttling). Explicit R still
    -- refreshes from the network.
    auto_fetch = true,
  },
}

---@type MsTeams.Config
M.options = {}

---@param opts? MsTeams.Config
---@return MsTeams.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {}) --[[@as MsTeams.Config]]
  vim.fn.mkdir(M.options.data_dir, "p")
  return M.options
end

return M
