# ms-teams.nvim

> **UNSTABLE — very early stage of development.** Breaking changes happen
> without notice, error handling is thin, and parts of the UI are still
> rough. Use at your own risk.

Minimal Microsoft Teams chats inside Neovim, via Microsoft Graph.
File/tab attachments can be opened in the browser with `gx`.

## Authentication: built on top of DavMail

This plugin does **not** implement its own OAuth login. It reuses the
DavMail OAuth token:

- You authenticate once with DavMail (`davmail-token`, JavaFX browser
  window), which writes `oauth_tokens.env` (path taken from
  `davmail.oauth.tokenFilePath` in `~/.davmail.properties`).
- The plugin reads and decrypts that refresh token
  (`lua/ms-teams/davmail_token.lua`, including `{AES}` values via the
  DavMail jar) and exchanges it for Graph access tokens, cached in
  `vim.fn.stdpath("data")/ms-teams/davmail_access.json` (`chmod 600`).
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
  dir = "~/projects/ms-teams.nvim",
  dev = true,
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

## Commands

* `:MSTeamsLogin` / `:MSTeamsCode <url>` / `:MSTeamsLoginCancel` — legacy OAuth flow (untested)
* `:MSTeamsRegisterProtocol` — macOS `ms-appx-web://` protocol handler (legacy flow)
* `:MSTeamsStatus` — token status and expiry
* `:MSTeamsTokenScopes` — scopes of the current access token
* `:MSTeamsChats` — recent chats list (`R` refresh, `g?` participants, `mr`/`mu` mark read/unread)
* `:MSTeamsTeams` — teams and channels
* `:MSTeamsFind` — Telescope fuzzy find over chats (`<C-b>` unread/all)
* `:MSTeamsNewChat` — new chat picking a user via Telescope
* `:MSTeamsReply` / `S` — reply in chat buffer
* `:MSTeamsWatchStart` / `Stop` / `Status` / `Poll` / `Restart` — watch polling

## Storage

* `stdpath("data")/ms-teams/davmail_access.json` — cached Graph access token (`chmod 600`)
* `stdpath("data")/ms-teams/chats.json`, `teams*.json` — list caches
* `stdpath("cache")/ms-teams/attachments` — downloaded images/files
