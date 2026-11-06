# ms-teams.nvim

> **UNSTABLE — very early stage of development.** Breaking changes happen
> without notice, error handling is thin, and parts of the UI are still
> rough. Use at your own risk.

Microsoft Teams chats inside Neovim, read and answer microsoft teams chats right inside your editor

## Demo

[![Watch the demo](https://img.youtube.com/vi/p24sI_XM27E/0.jpg)](https://www.youtube.com/watch?v=p24sI_XM27E)

## Authentication: built on top of DavMail

This plugin does **not** implement its own OAuth login. It reuses the
DavMail OAuth token:

- You authenticate once with DavMail (`davmail-token`, JavaFX browser
  window), which writes `oauth_tokens.env` (path taken from
  `davmail.oauth.tokenFilePath` in `~/.davmail.properties`).
- The plugin reads that refresh token (`lua/ms-teams/davmail_token.lua`)
  and exchanges it for Graph access tokens, cached in
  `vim.fn.stdpath("data")/ms-teams/davmail_access.json` (`chmod 600`).
- Plaintext tokens are supported and tested. Tokens stored as `{AES}`
  are decrypted by delegating to DavMail's own `O365Token.load()` via
  a small Java helper compiled against `davmail.jar` — this path is
  **untested**. The decryption password comes from `davmail.password`
  in `setup()`, else `davmail.oauth.password` in `.davmail.properties`,
  else empty string.
- Extra Graph scopes (beyond what DavMail requests) go in
  `davmail.oauth.scope` in `.davmail.properties`, then re-run
  `davmail-token` to reconsent.
- If the token file is missing/empty, the plugin can auto-launch the
  configured `davmail.auth_cmd` (default `davmail-token`).

The `davmail-token` alias runs the DavMail jar in interactive token
mode (JavaFX browser window for the Microsoft login). Add it to your
`~/.zshrc` (adjust the jar path to your install):

```zsh
alias davmail-token='JAVA_HOME=$HOME/.sdkman/candidates/java/current java --add-exports java.base/sun.net.www.protocol.https=ALL-UNNAMED -jar /opt/homebrew/Cellar/davmail/6.8.1/libexec/davmail.jar <(cat ~/.davmail.properties; echo "davmail.mode=O365Interactive") -token'
```

It loads your `~/.davmail.properties` (including `davmail.oauth.scope`
and `davmail.oauth.tokenFilePath`), forces `davmail.mode=O365Interactive`,
and the `-token` flag prints/saves the refresh token instead of starting
the gateway.

Fallback: a legacy first-party client
(`a8759234-4b8b-4d94-8c0a-ee1ab73af270`) with its own OAuth flow still
exists in `lua/ms-teams/auth.lua`, but it is **untested** — DavMail mode
is the only supported path right now.

## Architecture

```
DavMail oauth_tokens.env  ──►  davmail_token.lua  ──►  auth.lua
         (refresh token,          (decrypt + refresh       (token
          {AES} or plain)          → access token)          provider)
                                                              │
                                                              ▼
                                                     graph.lua ──► Microsoft Graph
                                                     (curl via          (chats, messages,
                                                      vim.system)        teams, tabs, files)
                                                              │
                                                              ▼
                                                     ui.lua ──► scratch buffers
                                                     (ms-teams://…       + Telescope
                                                      render + gx)        pickers
watch.lua ──► poll lastMessagePreview ──► terminal-notifier / notify-send
cache.lua ──► chats/teams/messages JSON under stdpath("data")/ms-teams
config.lua ──► setup() options (scope, icons, watch, open_cmd, davmail)
```

- **auth flow**: every Graph call goes through `auth.get_token()` /
  `ensure_token_async()`, which prefer the DavMail token when
  `davmail.enabled` is true.
- **tabs/files**: `tabReference` attachments are resolved via
  `GET /chats/{id}/tabs`; SharePoint files prefer a `createLink`
  (`/:x:/…?e=…`) sharing URL so they open without an interactive
  login. `gx` opens SharePoint URLs with `?web=1` (Excel Online,
  collaborative) using the configurable `open_cmd`.
- **watch**: single-instance polling (`data_dir/watch.lock`) while nvim
  is open; notifies on new messages/mentions even if focus is in Chrome.

## Setup (lazy.nvim)

```lua
{
  "jugarpeupv/microsoft-teams.nvim",
  cmd = { "MSTeamsChats", "MSTeamsLogin", "MSTeamsFind", "MSTeamsTeams" },
  keys = {
    { "<leader>ee", "<cmd>MSTeamsChats<cr>" },
    { "<leader>ef", "<cmd>MSTeamsFind<cr>" },
  },
  config = function()
    require("ms-teams").setup({
      davmail = {
        enabled = true,
        auth_cmd = "davmail-token",
      },
      -- pin a Chrome profile holding the M365 session for gx:
      -- open_cmd = {"open", "-a", "Google Chrome", "--args", "--profile-directory=Profile 3"},
      watch = { enabled = true, interval_ms = 120000 },
    })
  end,
}
```

Requires `telescope.nvim`. For watch notifications:
`brew install terminal-notifier` (fallback to `notify-send` on Linux).

## Keymaps

Keymaps are configurable per buffer under `keymaps`:

* `chat_list` — `:MSTeamsChats` list
* `msteams_finder` — `:MSTeamsFind` Telescope picker
* `chat_detail` — chat detail buffer
* `user_detail` — user detail buffer

Defaults are deep-merged, so you only override what you need. Setting an
action to `false` (or `""`) removes its mapping and its hint.

```lua
require("ms-teams").setup({
  keymaps = {
    chat_list = {
      open = "go",            -- default: <CR>
      mark_read = "mr",       -- also works on a visual selection
      user_detail = "mp",     -- 1:1 chat under cursor
    },
    msteams_finder = {
      open = "<CR>",
      user_detail = "<C-i>",  -- 1:1 chats only; groups/channels are rejected
      quickfix = "<C-q>",
    },
    chat_detail = {
      user_detail = "gu",     -- default: mp (1:1 chats only)
      close = false,          -- disable q
    },
    user_detail = {
      open_photo = "gx",      -- default: gx
      refresh = "R",          -- re-fetch profile after throttling
    },
  },
})
```

The complete list of actions and their default keys is the source of truth in
[`lua/ms-teams/config.lua`](lua/ms-teams/config.lua) (see
`M.defaults.keymaps`); refer to that file if a default changes.

## Commands

* `:MSTeamsLogin` / `:MSTeamsCode <url>` / `:MSTeamsLoginCancel` — legacy OAuth flow (untested)
* `:MSTeamsRegisterProtocol` — macOS `ms-appx-web://` protocol handler (legacy flow)
* `:MSTeamsStatus` — token status and expiry
* `:MSTeamsTokenScopes` — scopes of the current access token
* `:MSTeamsChats` — recent chats list (`R` refresh, `g?` participants, `mr`/`mu` mark read/unread; chats with the same name get a short id suffix)
* `:MSTeamsTeams` — teams and channels
* `:MSTeamsFind` — Telescope fuzzy find over chats (`<C-b>` unread/all)
* `:MSTeamsNewChat` — new chat picking a user via Telescope
* `:MSTeamsReply` / `S` — reply in chat buffer
* `:MSTeamsWatchStart` / `Stop` / `Status` / `Poll` / `Restart` — watch polling

## User detail

`mp` opens the selected user's detail buffer
(`ms-teams://user-detail/<id>`):

* `<C-i>` in `:MSTeamsFind` (only for 1:1 chats; groups/channels show a notice;
  override with `keymaps.msteams_finder.user_detail`),
* `mp` in `:MSTeamsChats` on a 1:1 chat (override with
  `keymaps.chat_list.user_detail`),
* `mp` in a 1:1 chat buffer (override with
  `keymaps.chat_detail.user_detail`; `nil`/`false` disables the mapping),
* `<CR>` on a participant in `g?`.

The buffer shows the Graph profile fields the token can read (name,
email, job title, department, company, office, phones, language, city,
country, account status, creation date) plus the profile photo. Profiles
are cached in `stdpath("cache")/ms-teams/user_profiles.json`, so data
fetched once stays visible during 429 windows; `R` forces a refresh
(override with `keymaps.user_detail.refresh`). If the profile call is
throttled and nothing is cached, the title still uses the name learned
from chat members or the persisted identity cache, the member email is
shown when available, and the id is shown as a field instead of the
title. When
`image.nvim` is available the avatar is rendered inline at the top of the
buffer, cropped into a circle with ImageMagick like Teams; otherwise the
cached path is shown and `gx` opens it. Photos are cached under
`stdpath("cache")/ms-teams/avatars` and revalidated with their etag, so
reopening a user costs no network.

Names resolved through `/users` are persisted in
`stdpath("cache")/ms-teams/user_names.json`, so the directory lookup
queue stays idle across sessions instead of re-requesting the same ids.

## Live refresh (1:1 chats)

Microsoft Graph has no push channel usable from a local editor for chat
messages (change notifications require a public HTTPS endpoint and 60-minute
subscription renewals; delta is not supported for `chatMessage`). Instead, an
open 1:1 chat buffer is polled and new/updated messages are merged in place:

```lua
require("ms-teams").setup({
  refresh_one_to_one_chats_opts = {
    enabled = true,
    interval_ms = 10000,  -- clamped to a 10s minimum
    top = 20,             -- newest messages merged when something changed
    only_visible = true,  -- skip while the buffer is not on screen
    lock = true,          -- single Neovim instance per chat
  },
})
```

Only 1:1 chats are polled; groups, meetings and channels are not. A 429 pauses
polling for 60s instead of retrying.

With `lock = true` (default) a per-chat lock under
`stdpath("data")/ms-teams/live/` makes the poll follow the editor you are in:
opening or focusing a 1:1 chat **steals** the lock from older instances (last
one wins). The new owner announces the takeover (chat name + PID/process/cwd)
and the previous owner pauses with its own notice naming the chat, e.g.
`took over lock from PID 1234 (nvim) cwd=/home/me/proj` (new owner) and
`live refresh lock for Rubén Panadero was taken over by ...` (old owner).
Hiding/closing the buffer releases the
lock, and a dead pid or a heartbeat older than `3 × interval` (min 30s) can be
taken over. Set `lock = false` to let every instance poll independently.

The chat-list watch (`:MSTeamsWatchStart`, `watch.enabled`) uses the same
steal semantics for `stdpath("data")/ms-teams/watch.lock`: a newly started
instance takes over and the previous one stops on its next poll with the same
PID/process/cwd notice.

## Searching in a chat

Inside a chat detail buffer:

* `g/` — search full history (server-side, smart-case: `hello` is
  case-insensitive, `Hello` is case-sensitive). Results open in a
  vertical split as snippets; `<CR>` (also `gx`/`gf`) moves the detail
  cursor to the message — loading older history in the background if
  needed — while focus stays in results. `<C-q>` sends results to the
  quickfix list. `q` closes.
* `gF` — same search in a Telescope picker; `<CR>` jumps to the
  message, `<C-q>` / `<M-q>` send all / selected results to the
  quickfix list, then navigate with `:cnext` / `:cprev`.
* Jumped matches are underlined red (configurable via
  `setup({ highlights = { search = "DiagnosticUnderlineError" } })`).

## Storage

* `stdpath("data")/ms-teams/davmail_access.json` — cached Graph access token (`chmod 600`)
* `stdpath("data")/ms-teams/chats.json`, `teams*.json` — list caches
* `stdpath("cache")/ms-teams/attachments` — downloaded images/files
* `stdpath("cache")/ms-teams/avatars` — cached profile photos (etag-revalidated)
* `stdpath("cache")/ms-teams/user_profiles.json` — cached user profiles (429-safe, `R` refreshes)
* `stdpath("cache")/ms-teams/user_names.json` — persisted id → displayName cache
