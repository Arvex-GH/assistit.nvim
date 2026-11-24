---@mod assistit Ultra-lightweight local-first hybrid AI coding companion for Neovim
local cache = require("assistit.cache")
local commands = require("assistit.commands")
local completion = require("assistit.completion")
local config = require("assistit.config")
local deterministic = require("assistit.deterministic")
local diagnostics = require("assistit.diagnostics")
local generation = require("assistit.generation")
local index = require("assistit.context.index")
local personalization = require("assistit.personalization")
local preview = require("assistit.ui.preview")
local status_ui = require("assistit.ui.status")
local ui = require("assistit.ui")

local M = {
  version = "0.1.0",
}

M._initialized = false
M._lifecycle_group = nil

---Configure and activate `assistit.nvim`.
---@param opts? table
---@return boolean ok
function M.setup(opts)
  local ok, cfg_or_errors, warnings = config.setup(opts)
  if not ok then
    local err_list = table.concat(cfg_or_errors --[[@as string[] ]], "\n  - ")
    vim.notify("[assistit] Invalid configuration:\n  - " .. err_list, vim.log.levels.ERROR)
    return false
  end

  local cfg = cfg_or_errors --[[@as table]]
  for _, w in ipairs(warnings or {}) do
    vim.notify("[assistit] " .. w, vim.log.levels.WARN)
  end

  ui.setup_highlights()
  commands.setup()
  personalization.load(cfg)

  if M._lifecycle_group then
    pcall(vim.api.nvim_del_augroup_by_id, M._lifecycle_group)
  end
  M._lifecycle_group = vim.api.nvim_create_augroup("AssistItLifecycle", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = M._lifecycle_group,
    callback = function()
      ui.setup_highlights()
    end,
    desc = "assistit: refresh default highlight links on colorscheme change",
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = M._lifecycle_group,
    callback = function()
      completion.cancel_inflight()
      personalization.save(config.get())
    end,
    desc = "assistit: flush local personalization stats and stop active curl jobs",
  })

  if cfg.enabled then
    deterministic.setup(cfg)
    completion.setup(cfg)
    diagnostics.setup(cfg)
    if cfg.index and cfg.index.enabled then
      index.build(cfg)
    end
  else
    deterministic.teardown()
    completion.teardown()
    diagnostics.teardown()
  end

  M._initialized = true
  return true
end

local function ensure_initialized()
  if not M._initialized then
    M.setup({})
  end
end

function M.enable()
  ensure_initialized()
  local cfg = config.get()
  cfg.enabled = true
  deterministic.setup(cfg)
  completion.setup(cfg)
  diagnostics.setup(cfg)
  ui.notify("Enabled (profile: " .. cfg.profile .. ").", vim.log.levels.INFO, true)
end

function M.disable()
  local cfg = config.get()
  cfg.enabled = false
  completion.teardown()
  deterministic.teardown()
  diagnostics.teardown()
  preview.close()
  ui.notify("Disabled.", vim.log.levels.INFO, true)
end

function M.toggle()
  if config.get().enabled then
    M.disable()
  else
    M.enable()
  end
end

function M.status()
  ensure_initialized()
  status_ui.open()
end

---@return string
function M.statusline()
  return status_ui.statusline()
end

function M.complete()
  ensure_initialized()
  completion.trigger({ manual = true })
end

function M.complete_block()
  ensure_initialized()
  completion.trigger({ manual = true, block = true })
end

---@param mode? "full"|"word"|"line"
---@return boolean
function M.accept(mode)
  if preview.active_proposal and preview.active_proposal.target_buf >= 0 then
    return preview.accept_active()
  end
  return completion.progressive.accept(mode or "full")
end

function M.dismiss()
  if preview.active_proposal then
    preview.reject_active()
    return
  end
  completion.dismiss()
end

function M.explain(opts)
  ensure_initialized()
  generation.explain(opts)
end

function M.fix(opts)
  ensure_initialized()
  diagnostics.fix(opts)
end

function M.refactor(opts)
  ensure_initialized()
  generation.refactor(opts)
end

function M.review(opts)
  ensure_initialized()
  generation.review(opts)
end

function M.test(opts)
  ensure_initialized()
  generation.test(opts)
end

function M.doc(opts)
  ensure_initialized()
  generation.doc(opts)
end

function M.optimize(opts)
  ensure_initialized()
  generation.optimize(opts)
end

function M.generate(instruction)
  ensure_initialized()
  generation.generate(instruction)
end

function M.cleanup()
  ensure_initialized()
  local bufnr = vim.api.nvim_get_current_buf()
  local removed_imp = deterministic.transforms.remove_duplicate_imports(bufnr)
  local stripped_ws = deterministic.transforms.strip_trailing_whitespace(bufnr)
  diagnostics.quality.run_buffer(bufnr)
  ui.notify(
    string.format("Cleanup complete: removed %d duplicate imports, trimmed %d lines.", removed_imp, stripped_ws),
    vim.log.levels.INFO,
    true
  )
end

function M.index(opts)
  ensure_initialized()
  local cfg = config.get()
  index.build(cfg, {
    sync = opts and opts.sync,
    on_done = function(sum)
      ui.notify(
        string.format("Indexed %d files (%d symbols) in %s.", sum.file_count, sum.symbol_count, tostring(sum.root)),
        vim.log.levels.INFO,
        true
      )
    end,
  })
end

function M.set_profile(profile_name)
  ensure_initialized()
  local ok, msg = config.set_profile(vim.trim(profile_name or ""))
  if not ok then
    ui.notify(msg, vim.log.levels.ERROR, true)
    return false
  end
  local cfg = config.get()
  if cfg.enabled then
    completion.setup(cfg)
    diagnostics.setup(cfg)
  end
  ui.notify(msg, vim.log.levels.INFO, true)
  return true
end

function M.clear_cache()
  cache.global:clear()
  ui.notify("Completion cache cleared.", vim.log.levels.INFO, true)
end

function M.reset_learning()
  personalization.reset(config.get())
  ui.notify("Local personalization preferences reset.", vim.log.levels.INFO, true)
end

return M
