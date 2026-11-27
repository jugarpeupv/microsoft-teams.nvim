local tmp = vim.fn.tempname() .. "-ms-nofixwidth"
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
vim.env.XDG_DATA_HOME = tmp .. "/data"
local src = debug.getinfo(1, "S").source:sub(2)
local root = src:match("^(.*)/tests/[^/]+$") or vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("ms-teams").setup({ watch = { enabled = false } })

local ms = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(ms, "ms-teams://test")
vim.api.nvim_win_set_buf(0, ms)
vim.wo.winfixwidth = true
local ms_win = vim.api.nvim_get_current_win()

vim.cmd("vsplit")
local normal = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(normal, "normal-test.txt")
vim.api.nvim_win_set_buf(0, normal)
vim.wo.winfixwidth = true
local normal_win = vim.api.nvim_get_current_win()

vim.api.nvim_exec_autocmds("WinEnter", {})
assert(vim.api.nvim_get_option_value("winfixwidth", { win = ms_win }) == false,
  "ms-teams window still has winfixwidth")
assert(vim.api.nvim_get_option_value("winfixwidth", { win = normal_win }) == true,
  "normal window was modified")

-- moving back into the ms-teams window re-applies the fix
vim.api.nvim_set_current_win(ms_win)
vim.wo.winfixwidth = true
vim.api.nvim_exec_autocmds("WinEnter", {})
assert(vim.api.nvim_get_option_value("winfixwidth", { win = ms_win }) == false,
  "winfixwidth not cleared on WinEnter")
print("NO_WINFIXWIDTH_OK")
vim.fn.delete(tmp, "rf")
vim.cmd("qa!")
