# ms-teams.nvim

Minimal Neovim Teams chats via Microsoft Graph using two first-party pre-consented clients (no admin consent) - `read` via `b20d0d3a... SalesInsights` `Chat.Read` and `send` via `1fec8e78... Microsoft Teams` `ChatMessage.Send`, same `auth.bash` PKCE flow as `davmail` but dual tokens.

## Why 2 logins?

`GraphPreConsent.yaml` shows no single `first-party` client has both `Chat.Read` + `ChatMessage.Send` pre-consented for `Graph 00000003...` without `65002`. Product `Teams` itself uses `FOCI` `BroCI` to combine `read`+`send` across clients. This plugin does same with two independent `PKCE` flows:

1. `:MSTeamsLogin` opens browser for **read** (`b20d0d3a` `Chat.Read` `nativeclient`) -> paste `code` -> `~/.local/share/nvim/ms-teams/read.json`
2. immediately opens second browser for **send** (`1fec8e78` `ChatMessage.Send`) -> paste `code` -> `~/.local/share/nvim/ms-teams/send.json`

Second login is quick via `SSO` cookie (select account, no password). Afterwards `offline_access` `refresh_token` handles silently.

*(Nota: Dado que el cliente pre-consentido por defecto `b20d0d3a` solo tiene permisos de lectura `Chat.Read`, las acciones de ocultar chat (`<C-x>`) y marcar como leído (`gL`) se ejecutan y persisten localmente en Neovim de manera transparente. Si deseas que estas acciones se sincronicen en el servidor, puedes registrar tu propia aplicación en Entra ID con permisos `Chat.ReadWrite` y configurar los `clients` en la inicialización).*

To use single token (read+send) create own `Entra ID` app (`public http://localhost`, `delegated Chat.ReadWrite ChatMessage.Send`, one `admin consent`) and override `config.clients` to same `client_id`.

## Setup (lazy.nvim)

```lua
{
  "local/ms-teams.nvim",
  dev = true,
  dir = "~/projects/ms-teams.nvim",
  cmd = { "MSTeamsChats", "MSTeamsLogin" },
  keys = { { "<leader>mt", "<cmd>MSTeamsChats<cr>", desc = "Teams chats" } },
  config = function()
    require("ms-teams").setup({
      -- optional override to own app:
      -- clients = {
      --   read = { client_id="your-guid", redirect_uri="http://localhost", scope="offline_access Chat.ReadWrite" },
      --   send = { client_id="your-guid", redirect_uri="http://localhost", scope="offline_access ChatMessage.Send" },
      -- }
    })
  end,
}
```

## Watch / Notificaciones (opción A - mientras nvim abierto)

Polling con `vim.uv` + `terminal-notifier` — sigue disparando aunque el foco esté en Chrome, mientras el proceso `nvim` siga vivo. Cada poll hace `GET /me/chats?$expand=members,lastMessagePreview` y compara `lastMessagePreview` vs `seen`, actualiza el cache `~/.cache/nvim/ms-teams/chats.json` (mismo que `cache.lua:23`) y dispara notificación macOS.

```lua
-- autostart cada 60s
require("ms-teams").setup({
  watch = {
    enabled = true,
    interval_ms = 60000, -- min 10000
    notifier = "auto", -- auto -> terminal-notifier | notify-send | vim.notify
    sound = "default", -- false para silencio
  }
})
```

Manual: `:MSTeamsWatchStart` / `:MSTeamsWatchStop` / `:MSTeamsWatchStatus` / `:MSTeamsWatchPoll` / `:MSTeamsWatchRestart`.

Requiere `brew install terminal-notifier` (fallback a `notify-send` en Linux o `vim.notify`).

## Commands

* `:MSTeamsLogin` - login both read+send (2 browser windows)
* `:MSTeamsLoginRead` / `:MSTeamsLoginSend` - single
* `:MSTeamsStatus` - show scopes/expiry
* `:MSTeamsChats` - picker for chats -> buffer with messages, `<leader>m` to reply
* `:MSTeamsReply` - reply in current chat buffer
* `:MSTeamsWatchStart` / `Stop` / `Status` / `Poll` - watch polling + notificaciones

## Storage

`vim.fn.stdpath("data")/ms-teams/read.json` and `send.json` (`chmod 600`) like `davmail.oauth.tokenFilePath`.

## Graph

* Read/Write: `GET /me/chats`, `POST /chats/{id}/markChatReadForUser`, `POST /chats/{id}/hideForUser` (`Chat.ReadWrite`)
* Send: `POST /chats/{id}/messages` (`ChatMessage.Send`)
