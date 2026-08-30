local config = require("ms-teams.config")
local auth = require("ms-teams.auth")
local ui = require("ms-teams.ui")

local M = {}

function M.setup(opts)
  config.setup(opts)
  -- cache /me for is_from_me (no hardcode)
  vim.defer_fn(function()
    pcall(function()
      local ok, cache = pcall(require, "ms-teams.cache")
      if ok and cache then
        local cached = cache.load("me", 86400)
        if not cached then
          require("ms-teams.graph").get_me(function(me, err)
            if me and me.id then
              cache.save("me", { id = me.id, displayName = me.displayName, mail = me.mail })
              vim.g.ms_teams_me_id = me.id
              vim.g.ms_teams_me_name = me.displayName
            end
          end)
        else
          vim.g.ms_teams_me_id = cached.id
          vim.g.ms_teams_me_name = cached.displayName
        end
      end
    end)
  end, 500)
  -- commands
  vim.api.nvim_create_user_command("MSTeamsLogin", function() auth.login_all() end, { desc = "Teams login (read+send, 2 browser windows)" })
  vim.api.nvim_create_user_command("MSTeamsLoginRead", function() auth.login("read") end, { desc = "Teams login read (Chat.Read)" })
  vim.api.nvim_create_user_command("MSTeamsLoginSend", function() auth.login("send") end, { desc = "Teams login send (ChatMessage.Send)" })
  vim.api.nvim_create_user_command("MSTeamsStatus", function() auth.status() end, { desc = "Teams token status" })
  vim.api.nvim_create_user_command("MSTeamsChats", function() ui.pick_chats() end, { desc = "Teams list chats" })
  vim.api.nvim_create_user_command("MSTeamsReply", function() ui.reply() end, { desc = "Teams reply to current chat" })
  vim.api.nvim_create_user_command("MSTeamsWatchStart", function() require("ms-teams.watch").start() end, { desc = "Teams start watch (poll + terminal-notifier)" })
  vim.api.nvim_create_user_command("MSTeamsWatchStop", function() require("ms-teams.watch").stop() end, { desc = "Teams stop watch" })
  vim.api.nvim_create_user_command("MSTeamsWatchStatus", function() require("ms-teams.watch").status() end, { desc = "Teams watch status" })
  vim.api.nvim_create_user_command("MSTeamsWatchPoll", function() require("ms-teams.watch").poll_once() end, { desc = "Teams watch poll once" })
  vim.api.nvim_create_user_command("MSTeamsWatchRestart", function() require("ms-teams.watch").restart() end, { desc = "Teams watch restart" })

  -- autostart if configured: watch.enabled=true
  -- timer runs via vim.uv (vim.loop) -> sigue disparando aunque el foco esté en Chrome,
  -- mientras el proceso nvim siga vivo. No necesita focus.
  if config.options.watch and config.options.watch.enabled then
    vim.defer_fn(function() pcall(require("ms-teams.watch").start) end, 1000)
  end
end

return M
