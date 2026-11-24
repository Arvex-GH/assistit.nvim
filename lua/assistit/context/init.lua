---@mod assistit.context Cursor-aware, budget-strict context extraction engine
local buffer_intel = require("assistit.deterministic.buffer_intel")
local index = require("assistit.context.index")
local lsp = require("assistit.lsp")
local metrics = require("assistit.metrics")
local privacy = require("assistit.privacy")
local util = require("assistit.util")

local M = {
  index = index,
}

---Comment prefix for a given filetype/language so metadata headers remain syntactically valid comments.
---@param ft string
---@return string
function M.comment_leader(ft)
  if ft == "lua" or ft == "sql" or ft == "haskell" or ft == "ada" then
    return "-- "
  elseif
    ft == "python"
    or ft == "sh"
    or ft == "bash"
    or ft == "zsh"
    or ft == "fish"
    or ft == "yaml"
    or ft == "ruby"
    or ft == "toml"
    or ft == "perl"
    or ft == "r"
    or ft == "julia"
    or ft == "elixir"
    or ft == "dockerfile"
    or ft == "make"
  then
    return "# "
  elseif ft == "vim" then
    return '" '
  elseif ft == "tex" or ft == "erlang" or ft == "matlab" then
    return "% "
  end
  return "// "
end

---Extract bounded, secret-redacted editing context around the active cursor.
---@param bufnr? integer
---@param winid? integer
---@param cfg? table
---@param opts? { prefix_scale?: number, suffix_scale?: number }
---@return table ctx
function M.extract(bufnr, winid, cfg, opts)
  local t0 = util.now_ms()
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  winid = winid or vim.api.nvim_get_current_win()
  cfg = cfg or require("assistit.config").get()
  opts = opts or {}

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local priv_cfg = cfg.privacy or {}
  local is_blocked, block_reason = privacy.is_sensitive_file(bufname, priv_cfg.blocked_file_patterns)
  if is_blocked then
    metrics.record_context_time(util.now_ms() - t0)
    return {
      blocked = true,
      reason = block_reason,
      bufnr = bufnr,
    }
  end

  local cursor = { 1, 0 }
  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
    cursor = vim.api.nvim_win_get_cursor(winid)
  end

  local row = cursor[1] -- 1-indexed
  local col = cursor[2] -- 0-indexed byte offset
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

  local ctx_cfg = cfg.context or {}
  local scale_pre = opts.prefix_scale or 1.0
  local scale_suf = opts.suffix_scale or 1.0
  local max_prefix_chars = math.floor((ctx_cfg.max_prefix_chars or 1200) * scale_pre)
  local max_suffix_chars = math.floor((ctx_cfg.max_suffix_chars or 400) * scale_suf)
  local max_extra_chars = math.floor(ctx_cfg.max_extra_chars or 350)

  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local max_above = math.min(row - 1, math.max(30, math.ceil(max_prefix_chars / 20)))
  local max_below = math.min(total_lines - row, math.max(15, math.ceil(max_suffix_chars / 20)))

  local start_line0 = math.max(0, (row - 1) - max_above)
  local end_line0 = math.min(total_lines, row + max_below)
  local window_lines = vim.api.nvim_buf_get_lines(bufnr, start_line0, end_line0, false)

  local language, filetype = lsp.treesitter.detect_language(bufnr, row - 1, col, window_lines)

  local rel_cursor_idx = row - start_line0 -- 1-indexed inside window_lines
  local current_line = window_lines[rel_cursor_idx] or ""
  -- In Normal mode, Neovim clamps cursor to `#line - 1` at EOL; treat EOL cursor as appending after the line
  local mode = vim.api.nvim_get_mode().mode
  if mode == "n" and #current_line > 0 and col >= #current_line - 1 then
    col = #current_line
  end
  local line_before = current_line:sub(1, col)
  local line_after = current_line:sub(col + 1)

  local lines_above = {}
  for i = 1, rel_cursor_idx - 1 do
    lines_above[#lines_above + 1] = window_lines[i]
  end

  local lines_below = {}
  for i = rel_cursor_idx + 1, #window_lines do
    lines_below[#lines_below + 1] = window_lines[i]
  end

  local prefix_above_budget = math.max(0, max_prefix_chars - #line_before - 1)
  local above_text, kept_above_count = util.tail_within_budget(lines_above, prefix_above_budget)
  local raw_prefix = above_text ~= "" and (above_text .. "\n" .. line_before) or line_before
  local effective_prefix_start0 = math.max(0, (row - 1) - kept_above_count)

  local suffix_below_budget = math.max(0, max_suffix_chars - #line_after - 1)
  local below_text = util.head_within_budget(lines_below, suffix_below_budget)
  local raw_suffix = below_text ~= "" and (line_after .. "\n" .. below_text) or line_after

  -- Build compact extra metadata header within strict `max_extra_chars`
  local extra_lines = {}
  local cmt = M.comment_leader(filetype)
  local cwd = vim.fn.getcwd()
  local rel_path = bufname
  if rel_path ~= "" and rel_path:sub(1, #cwd + 1) == cwd .. "/" then
    rel_path = rel_path:sub(#cwd + 2)
  end

  if rel_path ~= "" then
    extra_lines[#extra_lines + 1] = cmt .. "file: " .. rel_path .. " (" .. language .. ")"
  elseif language ~= "text" then
    extra_lines[#extra_lines + 1] = cmt .. "language: " .. language
  end

  local scope = nil
  if ctx_cfg.include_treesitter_scope ~= false then
    scope = lsp.treesitter.get_enclosing_scope(bufnr, row - 1, col)
    if scope and scope.start_row < effective_prefix_start0 and scope.signature ~= "" then
      extra_lines[#extra_lines + 1] = cmt .. "scope: " .. scope.signature
    end
  end

  -- Preserve top-of-file imports if cursor is deeper in the file than the truncated prefix budget
  if effective_prefix_start0 > 0 then
    local top_lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(35, effective_prefix_start0), false)
    local imports = {}
    for _, tl in ipairs(top_lines) do
      local key = buffer_intel.parse_import_line(tl, filetype)
      if key then
        imports[#imports + 1] = util.trim(tl)
        if #imports >= 6 then
          break
        end
      end
    end
    if #imports > 0 then
      extra_lines[#extra_lines + 1] = cmt .. "imports: " .. table.concat(imports, " | ")
    end
  end

  if ctx_cfg.include_diagnostics ~= false then
    local diags = lsp.get_diagnostics(bufnr, row - 1)
    if #diags > 0 and diags[1].message then
      local msg = diags[1].message:gsub("\n", " "):sub(1, 120)
      extra_lines[#extra_lines + 1] = cmt .. "diagnostic: " .. msg
    end
  end

  if ctx_cfg.include_project_symbols and index.state.indexed then
    local sym_budget = math.max(0, max_extra_chars - 120)
    local query_seed = (scope and scope.signature or "") .. " " .. line_before
    local rel_syms = index.query_relevant_symbols(query_seed, rel_path, sym_budget)
    if rel_syms ~= "" then
      for _, sline in ipairs(util.split_lines(rel_syms)) do
        extra_lines[#extra_lines + 1] = cmt .. "symbol: " .. sline
      end
    end
  end

  local raw_extra = util.head_within_budget(extra_lines, max_extra_chars)

  local redactions = 0
  if priv_cfg.redact_secrets ~= false then
    local r1, r2, r3
    raw_prefix, r1 = privacy.redact_secrets(raw_prefix)
    raw_suffix, r2 = privacy.redact_secrets(raw_suffix)
    raw_extra, r3 = privacy.redact_secrets(raw_extra)
    redactions = r1 + r2 + r3
  end

  local prev_lines_hash = util.hash(above_text)
  local suffix_hash = util.hash(raw_suffix)
  local indent_unit = buffer_intel.detect_indent(bufnr, window_lines)
  local cursor_kind = lsp.treesitter.cursor_context_kind(bufnr, row - 1, col)

  metrics.record_context_time(util.now_ms() - t0)

  return {
    blocked = false,
    bufnr = bufnr,
    winid = winid,
    bufname = bufname,
    rel_path = rel_path,
    filetype = filetype,
    language = language,
    row = row,
    col = col,
    changedtick = changedtick,
    current_line = current_line,
    line_before = line_before,
    line_after = line_after,
    prefix = raw_prefix,
    suffix = raw_suffix,
    extra = raw_extra,
    scope = scope,
    indent_unit = indent_unit,
    cursor_kind = cursor_kind,
    window_lines = window_lines,
    window_row = rel_cursor_idx,
    prev_lines_hash = prev_lines_hash,
    suffix_hash = suffix_hash,
    redactions = redactions,
  }
end

return M
