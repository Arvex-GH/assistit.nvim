---@mod assistit.ui Terminal-native highlights and non-intrusive notifications
local M = {}

---Define default highlight groups that adapt naturally to dark, light, and cterm colorschemes.
function M.setup_highlights()
  local groups = {
    AssistItGhost = { link = "Comment", default = true },
    AssistItSubtle = { link = "NonText", default = true },
    AssistItBorder = { link = "FloatBorder", default = true },
    AssistItTitle = { link = "Title", default = true },
    AssistItConfirmed = { link = "DiagnosticError", default = true },
    AssistItHint = { link = "DiagnosticInfo", default = true },
    AssistItHypothesis = { link = "DiagnosticWarn", default = true },
    AssistItActionKey = { link = "Special", default = true },
  }

  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

---Send a non-intrusive notification respecting `cfg.ui.notify_level`.
---@param msg string
---@param level? integer
---@param force? boolean
function M.notify(msg, level, force)
  level = level or vim.log.levels.INFO
  local cfg = require("assistit.config").get()
  local threshold = (cfg.ui and cfg.ui.notify_level) or vim.log.levels.WARN
  if force or level >= threshold then
    vim.notify("[assistit] " .. msg, level)
  end
end

return M
