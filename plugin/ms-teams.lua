-- auto-setup with defaults, user can override via require("ms-teams").setup({...})
if vim.g.loaded_ms_teams == 1 then return end
vim.g.loaded_ms_teams = 1
-- do not auto-setup to allow lazy setup in utilities.lua
