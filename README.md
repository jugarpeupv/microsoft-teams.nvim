# microsoft-teams.nvim

Minimal Neovim Teams chats via Microsoft Graph with a pre-consented first-party client (`a8759234-4b8b-4d94-8c0a-ee1ab73af270`), single login with `Chat.ReadWrite`, `ChatMessage.Send`, `Chat.Create` and `User.ReadBasic.All`.

## Setup (lazy.nvim)

```lua
{
  "jugarpeupv/microsoft-teams.nvim",
  cmd = { "MSTeamsChats", "MSTeamsLogin", "MSTeamsNewChat", "MSTeamsFind", "MSTeamsTeams" },
  keys = { { "<leader>mt", "<cmd>MSTeamsChats<cr>", desc = "Teams chats" }, { "<leader>mtc", "<cmd>MSTeamsTeams<cr>", desc = "Teams & channels" } },
  config = function()
    require("ms-teams").setup({
      highlights = {
        unread = "DiagnosticInfo", -- grupo de highlight para mensajes/chats no leídos
      },
    })
  end,
}
```

## Watch / Notificaciones (opción A - mientras nvim abierto)

Polling con `vim.uv` + `terminal-notifier` — sigue disparando aunque el foco esté en Chrome, mientras el proceso `nvim` siga vivo. Cada poll hace `GET /me/chats?$expand=members,lastMessagePreview` y compara `lastMessagePreview` vs `seen`, actualiza el cache `~/.cache/nvim/ms-teams/chats.json` y dispara notificación macOS.

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

* `:MSTeamsLogin` - Iniciar sesión OAuth (1 sola ventana de navegador, detección automática por protocolo/portapapeles)
* `:MSTeamsRegisterProtocol` - Instalar/registrar el manejador de protocolo macOS para `ms-appx-web://`
* `:MSTeamsCode <url>` - Introducir código o URL de OAuth manualmente si no se usa portapapeles
* `:MSTeamsLoginCancel` - Cancelar proceso de login activo
* `:MSTeamsStatus` - Ver estado y expiración del token
* `:MSTeamsChats` - Lista de chats recientes con búsqueda y detalles (`gS` para mostrar más/menos)
* `:MSTeamsTeams` - Lista de equipos y canales al estilo Microsoft Teams
* `:MSTeamsFind` - Fuzzy find sobre el top 50 de chats con Telescope (por defecto todos los chats, `<C-b>` para conmutar a no leídos)
* `:MSTeamsNewChat` - Crear / abrir un nuevo chat seleccionando usuario vía Telescope
* `:MSTeamsReply` / `S` - Responder en el buffer de chat (`<C-p>` para pegar imagen del portapapeles, `<C-s>` para enviar)
* `:MSTeamsWatchStart` / `Stop` / `Status` / `Poll` - Watch polling + notificaciones

## Storage

`vim.fn.stdpath("data")/ms-teams/token.json` (`chmod 600`).

## Graph

* Read/Write: `GET /me/chats`, `POST /chats/{id}/markChatReadForUser`, `POST /chats/{id}/hideForUser` (`Chat.ReadWrite`)
* Send: `POST /chats/{id}/messages` (`ChatMessage.Send`)
* Teams/Channels: `GET /me/joinedTeams`, `GET /teams/{team-id}/channels` (`Team.ReadBasic.All` requerido)
