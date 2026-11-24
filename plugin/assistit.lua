if vim.g.loaded_assistit == 1 then
  return
end
vim.g.loaded_assistit = 1

local v = vim.version()
if v.major == 0 and v.minor < 10 then
  vim.notify_once("[assistit.nvim] Requires Neovim >= 0.10.0.", vim.log.levels.WARN)
  return
end

require("assistit.ui").setup_highlights()
require("assistit.commands").setup()
