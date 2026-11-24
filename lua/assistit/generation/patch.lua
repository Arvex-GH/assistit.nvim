---@mod assistit.generation.patch Safe extraction of code blocks and summaries from model output
local util = require("assistit.util")

local M = {}

---Extract the first fenced code block (and any prose outside the fence as summary).
---If no markdown fence is present, treats the entire trimmed output as code.
---@param raw string
---@return string[] code_lines, string summary
function M.extract_code_and_summary(raw)
  if type(raw) ~= "string" or util.trim(raw) == "" then
    return {}, ""
  end

  local normalized = raw:gsub("\r\n", "\n")
  local f_start, f_end, _lang, code = normalized:find("```([%w_%-%.]*)\n(.-)\n```")
  if f_start and code then
    local prose_before = util.trim(normalized:sub(1, f_start - 1))
    local prose_after = f_end and util.trim(normalized:sub(f_end + 1)) or ""
    local summary_parts = {}
    if prose_before ~= "" then
      summary_parts[#summary_parts + 1] = prose_before
    end
    if prose_after ~= "" and #prose_before < 120 then
      summary_parts[#summary_parts + 1] = prose_after
    end
    return util.split_lines(code), table.concat(summary_parts, "\n")
  end

  -- Handle fence without trailing newline before closing backticks
  local b2_start, _, _lang2, code2 = normalized:find("```([%w_%-%.]*)\n(.-)```")
  if b2_start and code2 then
    local prose = util.trim(normalized:sub(1, b2_start - 1))
    return util.split_lines(code2), prose
  end

  return util.split_lines(util.trim(normalized)), ""
end

---Resolve target line range `(start_row0, end_row0)` from explicit range, visual marks, or Tree-sitter scope.
---@param bufnr integer
---@param opts? { line1?: integer, line2?: integer, range?: integer }
---@return integer start_row0, integer end_row0, string[] lines
function M.resolve_target_range(bufnr, opts)
  opts = opts or {}
  local total = vim.api.nvim_buf_line_count(bufnr)

  if opts.range and opts.range > 0 and opts.line1 and opts.line2 then
    local s0 = util.clamp(opts.line1 - 1, 0, math.max(0, total - 1))
    local e0 = util.clamp(opts.line2, s0 + 1, total)
    return s0, e0, vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
  end

  local pos = vim.api.nvim_win_get_cursor(0)
  local row0 = pos[1] - 1
  local col0 = pos[2]

  local ts = require("assistit.lsp.treesitter")
  local scope = ts.get_enclosing_scope(bufnr, row0, col0)
  if scope and scope.start_row and scope.end_row and scope.end_row >= scope.start_row then
    local s0 = util.clamp(scope.start_row, 0, math.max(0, total - 1))
    local e0 = util.clamp(scope.end_row + 1, s0 + 1, total)
    return s0, e0, vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
  end

  -- Fallback: small window around cursor line
  local s0 = util.clamp(row0, 0, math.max(0, total - 1))
  local e0 = util.clamp(row0 + 1, s0 + 1, total)
  return s0, e0, vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
end

return M
