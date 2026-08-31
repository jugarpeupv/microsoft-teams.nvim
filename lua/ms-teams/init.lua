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
  vim.api.nvim_create_user_command("MSTeamsLogin", function() auth.login_all() end, { desc = "Teams login (single window)" })
  vim.api.nvim_create_user_command("MSTeamsRegisterProtocol", function()
    local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/scripts/install-protocol-handler.sh"
    vim.notify("Installing macOS protocol handler for ms-appx-web://...", vim.log.levels.INFO)
    local out = vim.fn.system({ "bash", script })
    if vim.v.shell_error == 0 then
      vim.notify("MSTeams protocol handler registered successfully!", vim.log.levels.INFO)
    else
      vim.notify("Failed to register protocol handler: " .. out, vim.log.levels.ERROR)
    end
  end, { desc = "Register macOS ms-appx-web:// protocol handler" })
  vim.api.nvim_create_user_command("MSTeamsCode", function(opts) auth.submit_code(opts.args) end, { nargs = 1, desc = "Submit OAuth code/URL manually" })
  vim.api.nvim_create_user_command("MSTeamsLoginCancel", function() auth.cancel_login() end, { desc = "Cancel pending login" })
  vim.api.nvim_create_user_command("MSTeamsStatus", function() auth.status() end, { desc = "Teams token status" })
  vim.api.nvim_create_user_command("MSTeamsChats", function() ui.pick_chats() end, { desc = "Teams list chats" })
  vim.api.nvim_create_user_command("MSTeamsTeams", function() ui.pick_teams() end, { desc = "Teams list teams and channels" })
  vim.api.nvim_create_user_command("MSTeamsFind", function() ui.find_chats() end, { desc = "Teams fuzzy find chats with Telescope (<C-b> toggle unread/all)" })
  vim.api.nvim_create_user_command("MSTeamsNewChat", function() ui.new_chat() end, { desc = "Teams new chat with user via Telescope" })
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
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      pcall(function()
        local w = require("ms-teams.watch")
        if w.is_running and w.is_running() then w.stop() else
          -- ensure stale lock owned by this pid is removed even if watch not running
          local p = (config.options.data_dir or vim.fn.stdpath("data") .. "/ms-teams") .. "/watch.lock"
          if vim.fn.filereadable(p) == 1 then
            local ok, data = pcall(vim.fn.readfile, p)
            if ok and data and #data>0 then
              local ok2, j = pcall(vim.json.decode, table.concat(data,"\n"))
              if ok2 and j and tonumber(j.pid) == vim.fn.getpid() then pcall(vim.fn.delete, p) end
            end
          end
        end
      end)
    end,
  })
end

return M
