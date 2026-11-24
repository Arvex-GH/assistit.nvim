---@mod assistit.completion.ghost Native extmark ghost-text renderer
local util = require("assistit.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("assistit_ghost")

---@class AssistItActiveGhost
---@field bufnr integer
---@field row integer 1-indexed line
---@field col integer 0-indexed byte column
---@field text string Remaining suggestion text
---@field source string "ai"|"cache"|"deterministic"
---@field latency_ms number?
---@field extmark_id integer?
M.active = nil

M._spinner_extmark = nil
M._spinner_bufnr = nil

---Clear any currently rendered ghost text and optional spinner.
function M.clear()
  if M.active and M.active.bufnr and vim.api.nvim_buf_is_valid(M.active.bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, M.active.bufnr, M.ns, 0, -1)
  end
  M.active = nil
  M.clear_progress()
end

function M.clear_progress()
  if M._spinner_bufnr and vim.api.nvim_buf_is_valid(M._spinner_bufnr) and M._spinner_extmark then
    pcall(vim.api.nvim_buf_del_extmark, M._spinner_bufnr, M.ns, M._spinner_extmark)
  end
  M._spinner_extmark = nil
  M._spinner_bufnr = nil
end

---Render a subtle right-aligned indicator during slow CPU inference requests.
---@param bufnr integer
---@param row integer 1-indexed line
---@param label? string
function M.show_progress(bufnr, row, label)
  local cfg = require("assistit.config").get()
  if not cfg.ui or not cfg.ui.progress_indicator then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  M.clear_progress()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row0 = util.clamp((row or 1) - 1, 0, math.max(0, line_count - 1))
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, 0, {
    virt_text = { { " " .. (label or "⋯ assistit"), "AssistItSubtle" } },
    virt_text_pos = "right_align",
    hl_mode = "combine",
  })
  if ok then
    M._spinner_extmark = id
    M._spinner_bufnr = bufnr
  end
end

---Check whether an active ghost-text suggestion is visible at the current buffer.
---@param bufnr? integer
---@return boolean
function M.is_visible(bufnr)
  if not M.active or M.active.text == "" then
    return false
  end
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return M.active.bufnr == bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

---Return the currently active ghost suggestion table or nil.
---@return AssistItActiveGhost?
function M.get()
  return M.active
end

---Render `text` as ghost text at `(row, col)` in `bufnr`.
---@param bufnr integer
---@param row integer 1-indexed line
---@param col integer 0-indexed byte column
---@param text string
---@param meta? { source?: string, latency_ms?: number }
---@return boolean ok
function M.show(bufnr, row, col, text, meta)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not text or text == "" or not vim.api.nvim_buf_is_valid(bufnr) then
    M.clear()
    return false
  end

  local cfg = require("assistit.config").get()
  local hl = (cfg.ui and cfg.ui.ghost_hl_group) or "AssistItGhost"

  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, 0, -1)
  M._spinner_extmark = nil
  M._spinner_bufnr = nil

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row0 = util.clamp(row - 1, 0, math.max(0, line_count - 1))
  local cur_line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ""
  local col0 = util.clamp(col, 0, #cur_line)

  local lines = vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })
  local first_line = lines[1] or ""
  local virt_lines = {}

  for i = 2, #lines do
    virt_lines[#virt_lines + 1] = { { lines[i], hl } }
  end

  local ext_opts = {
    hl_mode = "combine",
  }

  if first_line ~= "" then
    ext_opts.virt_text = { { first_line, hl } }
    ext_opts.virt_text_pos = "inline"
  end

  if #virt_lines > 0 then
    ext_opts.virt_lines = virt_lines
  end

  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, col0, ext_opts)
  if not ok then
    -- Fallback to `eol` if `inline` fails for any edge-case column
    ext_opts.virt_text_pos = "eol"
    ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, col0, ext_opts)
    if not ok then
      return false
    end
  end

  meta = meta or {}
  if cfg.ui and (cfg.ui.show_source_badge or cfg.ui.show_latency_badge) then
    local badge_parts = {}
    if cfg.ui.show_source_badge and meta.source then
      badge_parts[#badge_parts + 1] = meta.source
    end
    if cfg.ui.show_latency_badge and meta.latency_ms and meta.latency_ms > 0 then
      badge_parts[#badge_parts + 1] = string.format("%dms", math.floor(meta.latency_ms))
    end
    if #badge_parts > 0 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, 0, {
        virt_text = { { " [" .. table.concat(badge_parts, " · ") .. "]", "AssistItSubtle" } },
        virt_text_pos = "right_align",
      })
    end
  end

  M.active = {
    bufnr = bufnr,
    row = row0 + 1,
    col = col0,
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    text = text,
    source = meta.source or "ai",
    latency_ms = meta.latency_ms,
    extmark_id = id,
  }

  return true
end

return M
