---@mod assistit.lsp.treesitter Optional Tree-sitter AST intelligence with graceful fallback
local util = require("assistit.util")

local M = {}

local SCOPE_NODE_TYPES = {
  function_declaration = "function",
  function_definition = "function",
  local_function = "function",
  function_stmt = "function",
  func_literal = "function",
  arrow_function = "function",
  function_item = "function",
  method_definition = "method",
  method_declaration = "method",
  class_definition = "class",
  class_declaration = "class",
  impl_item = "class",
  struct_item = "struct",
  struct_specifier = "struct",
}

---Attempt to obtain a parsed Tree-sitter root node for `bufnr`.
---@param bufnr integer
---@return userdata? root
local function get_root(bufnr)
  if not vim.treesitter or not vim.treesitter.get_parser then
    return nil
  end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not parser then
    return nil
  end
  local ok_tree, trees = pcall(parser.parse, parser)
  if not ok_tree or not trees or not trees[1] then
    return nil
  end
  return trees[1]:root()
end

---Fallback heuristic when no Tree-sitter grammar is installed for the buffer's filetype.
---@param bufnr integer
---@param row0 integer
---@return { kind: string, signature: string, start_row: integer, end_row: integer }?
local function fallback_scope(bufnr, row0)
  local start_scan = math.max(0, row0 - 80)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_scan, row0 + 1, false)
  for idx = #lines, 1, -1 do
    local line = util.trim(lines[idx])
    local r0 = start_scan + idx - 1
    if
      line:match("^local%s+function%s+")
      or line:match("^function%s+")
      or line:match("^def%s+[%w_]+")
      or line:match("^async%s+def%s+[%w_]+")
      or line:match("^pub%s+fn%s+[%w_]+")
      or line:match("^fn%s+[%w_]+")
      or line:match("^func%s+")
      or line:match("^export%s+function%s+")
    then
      return {
        kind = "function",
        signature = line,
        start_row = r0,
        end_row = row0,
      }
    elseif line:match("^class%s+[%w_]+") or line:match("^struct%s+[%w_]+") then
      return {
        kind = "class",
        signature = line,
        start_row = r0,
        end_row = row0,
      }
    end
  end
  return nil
end

---Find the nearest enclosing function, method, or class scope around `(row0, col0)`.
---@param bufnr integer
---@param row0 integer 0-indexed row
---@param col0 integer 0-indexed byte col
---@return { kind: string, signature: string, start_row: integer, end_row: integer }?
function M.get_enclosing_scope(bufnr, row0, col0)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local root = get_root(bufnr)
  if root then
    local ok_node, node = pcall(root.named_descendant_for_point_range, root, row0, col0, row0, col0)
    if ok_node and node then
      local cur = node
      while cur do
        local ntype = cur:type()
        local kind = SCOPE_NODE_TYPES[ntype]
        if kind then
          local sr, _, er, _ = cur:range()
          local header = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ""
          return {
            kind = kind,
            signature = util.trim(header),
            start_row = sr,
            end_row = er,
          }
        end
        cur = cur:parent()
      end
    end
  end
  return fallback_scope(bufnr, row0)
end

---Determine whether cursor is currently inside a comment or string literal.
---@param bufnr integer
---@param row0 integer
---@param col0 integer
---@return "comment"|"string"|"code"
function M.cursor_context_kind(bufnr, row0, col0)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return "code"
  end
  local check_col = math.max(0, col0 - 1)
  local root = get_root(bufnr)
  if root then
    local ok_node, node = pcall(root.named_descendant_for_point_range, root, row0, check_col, row0, check_col)
    if ok_node and node then
      local cur = node
      while cur do
        local t = cur:type()
        if t:find("comment", 1, true) then
          return "comment"
        end
        if t:find("string", 1, true) then
          return "string"
        end
        cur = cur:parent()
      end
      return "code"
    end
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ""
  local before = line:sub(1, col0)
  local trimmed = util.trim(before)
  if trimmed:match("^%-%-") or trimmed:match("^#") or trimmed:match("^//") or trimmed:match("^/%*") then
    return "comment"
  end
  return "code"
end

---Detect embedded fenced-block or tag language at `row0` inside markdown/html/vue/svelte buffers.
---@param bufnr integer
---@param row0 integer 0-indexed cursor line
---@param host_ft string
---@return string? embedded_lang
local function detect_embedded_block(bufnr, row0, host_ft)
  if host_ft == "markdown" or host_ft == "rmd" or host_ft == "quarto" or host_ft == "mdx" then
    local start_scan = math.max(0, row0 - 200)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_scan, row0 + 1, false)
    local open_lang = nil
    for i = 1, #lines - 1 do -- strictly lines above cursor row
      local l = lines[i] or ""
      local fence_tag = l:match("^%s*```+%s*([%w_%-%+#%.]+)")
      if fence_tag then
        if open_lang then
          open_lang = nil
        else
          open_lang = util.filetype_language(fence_tag)
        end
      elseif l:match("^%s*```+%s*$") then
        open_lang = nil
      end
    end
    return open_lang
  elseif host_ft == "html" or host_ft == "vue" or host_ft == "svelte" or host_ft == "astro" then
    local start_scan = math.max(0, row0 - 200)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_scan, row0 + 1, false)
    local active_tag = nil
    for i = 1, #lines - 1 do
      local l = (lines[i] or ""):lower()
      if l:find("<script", 1, true) and not l:find("</script>", 1, true) then
        active_tag = (l:find('lang="ts"', 1, true) or l:find("lang='ts'", 1, true)) and "typescript" or "javascript"
      elseif l:find("</script>", 1, true) then
        active_tag = nil
      elseif l:find("<style", 1, true) and not l:find("</style>", 1, true) then
        active_tag = "css"
      elseif l:find("</style>", 1, true) then
        active_tag = nil
      end
    end
    return active_tag
  end
  return nil
end

---Resolve the exact programming language at `(bufnr, row0, col0)` using:
---1) Embedded code fences / HTML-Vue-Svelte tags & Tree-sitter `language_for_range` injections
---2) Neovim buffer `filetype` & `vim.filetype.match`
---3) Shebang & syntax heuristics for unnamed/unsaved scratch buffers (`filetype == ""`)
---@param bufnr integer
---@param row0? integer 0-indexed row
---@param col0? integer 0-indexed col
---@param sample_lines? string[]
---@return string language, string effective_filetype
function M.detect_language(bufnr, row0, col0, sample_lines)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return "text", ""
  end
  row0 = row0 or 0
  col0 = col0 or 0

  local ft = vim.bo[bufnr].filetype or ""
  if ft == "" and vim.filetype and vim.filetype.match then
    local ok_m, matched_ft = pcall(vim.filetype.match, { buf = bufnr })
    if ok_m and type(matched_ft) == "string" and matched_ft ~= "" then
      ft = matched_ft
    end
  end

  -- 1. Check embedded fenced blocks / component tags first
  if ft ~= "" then
    local embedded = detect_embedded_block(bufnr, row0, ft)
    if embedded and embedded ~= "" then
      return embedded, embedded
    end
  end

  -- 2. Check Tree-sitter injected language tree at the exact cursor range
  if vim.treesitter and vim.treesitter.get_parser then
    local ok_p, parser = pcall(vim.treesitter.get_parser, bufnr)
    if ok_p and parser and parser.language_for_range then
      local ok_sub, sub_parser = pcall(parser.language_for_range, parser, { row0, col0, row0, col0 })
      if ok_sub and sub_parser and sub_parser.lang then
        local injected = sub_parser:lang()
        if
          type(injected) == "string"
          and injected ~= ""
          and injected ~= "markdown_inline"
          and injected ~= "comment"
          and injected ~= "jsdoc"
          and injected ~= "luadoc"
        then
          local norm = util.filetype_language(injected)
          return norm, norm
        end
      end
    end
  end

  -- 3. Use buffer filetype when known
  if ft ~= "" then
    return util.filetype_language(ft), ft
  end

  -- 4. Unsaved / unnamed buffer (`filetype == ""`): infer from shebang & code tokens
  local lines = sample_lines
  if not lines then
    local count = math.min(40, vim.api.nvim_buf_line_count(bufnr))
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, count, false)
  end
  local inferred = util.infer_language_from_lines(lines)
  return inferred, (inferred ~= "text" and inferred or "")
end

return M
