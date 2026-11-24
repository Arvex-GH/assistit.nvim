---@mod assistit.deterministic.buffer_intel Layer A static checks & instant micro-completions
local privacy = require("assistit.privacy")
local util = require("assistit.util")

local M = {}

---@class AssistItFinding
---@field lnum integer 1-indexed line number
---@field col integer 0-indexed column
---@field severity integer vim.diagnostic.severity.*
---@field code string
---@field category "import"|"unused"|"logic"|"complexity"|"security"|"style"
---@field provenance "deterministic"
---@field message string
---@field replacement? string Optional deterministic single-line replacement (`""` to delete line)

---Infer buffer indentation unit (e.g. `"  "` or `"    "` or `"\t"`).
---@param bufnr? integer
---@param lines? string[]
---@return string
function M.detect_indent(bufnr, lines)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    if not vim.bo[bufnr].expandtab then
      return "\t"
    end
    local sw = vim.bo[bufnr].shiftwidth
    if sw and sw > 0 then
      return string.rep(" ", sw)
    end
  end
  if lines then
    for _, line in ipairs(lines) do
      local tabs = line:match("^(\t+)%S")
      if tabs then
        return "\t"
      end
      local spaces = line:match("^( +)%S")
      if spaces and (#spaces == 2 or #spaces == 4) then
        return spaces
      end
    end
  end
  return "  "
end

---Extract imported module key and bound symbol (if any) from a source line.
---@param line string
---@param filetype string
---@return string? import_key
---@return string? bound_symbol
function M.parse_import_line(line, filetype)
  local trimmed = util.trim(line)
  if trimmed == "" or trimmed:match("^%-%-") or trimmed:match("^#") or trimmed:match("^//") then
    return nil, nil
  end

  if filetype == "lua" then
    local sym, mod = trimmed:match("^local%s+([%w_]+)%s*=%s*require%s*%(?%s*[\"']([^\"']+)[\"']%s*%)?$")
    if mod then
      return "lua:" .. mod, sym
    end
    local bare_mod = trimmed:match("^require%s*%(?%s*[\"']([^\"']+)[\"']%s*%)?$")
    if bare_mod then
      return "lua:" .. bare_mod, nil
    end
  elseif filetype == "python" then
    local mod, alias = trimmed:match("^import%s+([%w_%.]+)%s+as%s+([%w_]+)$")
    if mod then
      return "py:" .. mod, alias
    end
    local simple_mod = trimmed:match("^import%s+([%w_%.]+)$")
    if simple_mod then
      local root = simple_mod:match("^([%w_]+)")
      return "py:" .. simple_mod, root
    end
    local from_mod, sym = trimmed:match("^from%s+([%w_%.]+)%s+import%s+([%w_]+)$")
    if from_mod and sym then
      return "py:" .. from_mod .. ":" .. sym, sym
    end
  elseif
    filetype == "javascript"
    or filetype == "typescript"
    or filetype == "javascriptreact"
    or filetype == "typescriptreact"
  then
    local default_sym, mod = trimmed:match("^import%s+([%w_$]+)%s+from%s+[\"']([^\"']+)[\"'];?$")
    if mod then
      return "js:" .. mod .. ":default", default_sym
    end
    local named, mod2 = trimmed:match("^import%s*{%s*([%w_$]+)%s*}%s*from%s+[\"']([^\"']+)[\"'];?$")
    if mod2 then
      return "js:" .. mod2 .. ":" .. named, named
    end
    local req_sym, req_mod = trimmed:match("^(?:const|let|var)%s+([%w_$]+)%s*=%s*require%([\"']([^\"']+)[\"']%);?$")
    if not req_mod then
      req_sym, req_mod = trimmed:match("^const%s+([%w_$]+)%s*=%s*require%([\"']([^\"']+)[\"']%);?$")
    end
    if req_mod then
      return "js:" .. req_mod, req_sym
    end
  elseif filetype == "go" then
    local go_mod = trimmed:match("^import%s+\"([^\"]+)\"$")
    if go_mod then
      local pkg = go_mod:match("([^/]+)$")
      return "go:" .. go_mod, pkg
    end
  elseif filetype == "rust" then
    local rs_use = trimmed:match("^use%s+([%w_:]+);$")
    if rs_use then
      local sym = rs_use:match("([%w_]+)$")
      return "rs:" .. rs_use, sym
    end
  elseif filetype == "c" or filetype == "cpp" then
    local inc = trimmed:match("^#include%s*([<\"][^>\"]+[>\"])")
    if inc then
      return "c:" .. inc, nil
    end
  end

  return nil, nil
end

---Strip line comments trivially so identifier counting doesn't count commented-out words.
---@param line string
---@param filetype string
---@return string
local function strip_line_comment(line, filetype)
  if filetype == "lua" then
    return (line:gsub("%-%-.*$", ""))
  elseif filetype == "python" or filetype == "sh" or filetype == "bash" or filetype == "yaml" then
    return (line:gsub("#.*$", ""))
  else
    return (line:gsub("//.*$", ""))
  end
end

---Run fast deterministic static analysis on buffer lines.
---@param lines string[]
---@param opts? { filetype?: string, intensity?: "minimal"|"standard"|"deep" }
---@return AssistItFinding[]
function M.analyze_lines(lines, opts)
  opts = opts or {}
  local ft = opts.filetype or ""
  local intensity = opts.intensity or "standard"
  local findings = {}

  local seen_imports = {}
  local bound_imports = {}
  local local_defs = {}
  local token_counts = {}

  local indent_unit = M.detect_indent(nil, lines)
  local indent_width = indent_unit == "\t" and 1 or #indent_unit

  for lnum, line in ipairs(lines) do
    local code_only = strip_line_comment(line, ft)

    -- Count identifier tokens across the buffer in a single pass
    for word in code_only:gmatch("[%a_][%w_]*") do
      token_counts[word] = (token_counts[word] or 0) + 1
    end

    -- 1. Duplicate import check (runs in all intensities)
    local imp_key, imp_sym = M.parse_import_line(line, ft)
    if imp_key then
      if seen_imports[imp_key] then
        findings[#findings + 1] = {
          lnum = lnum,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          code = "duplicate_import",
          category = "import",
          provenance = "deterministic",
          message = string.format("Duplicate import (already imported on line %d).", seen_imports[imp_key]),
          replacement = "",
        }
      else
        seen_imports[imp_key] = lnum
        if imp_sym and not imp_sym:match("^_") then
          bound_imports[#bound_imports + 1] = { lnum = lnum, sym = imp_sym }
        end
      end
    elseif intensity ~= "minimal" then
      -- Track simple single-variable local declarations for unused variable hints
      if ft == "lua" then
        local loc = code_only:match("^%s*local%s+([%a_][%w_]*)%s*=")
        if loc and not loc:match("^_") and loc ~= "M" then
          local_defs[#local_defs + 1] = { lnum = lnum, sym = loc }
        end
      elseif ft == "javascript" or ft == "typescript" then
        local loc = code_only:match("^%s*const%s+([%a_$][%w_$]*)%s*=")
          or code_only:match("^%s*let%s+([%a_$][%w_$]*)%s*=")
        if loc and not loc:match("^_") then
          local_defs[#local_defs + 1] = { lnum = lnum, sym = loc }
        end
      end
    end

    -- 2. Suspicious tautological comparison `x == x` or `x ~= x` / `x != x`
    local lhs, op, rhs = code_only:match("([%a_][%w_%.]*)%s*([=~!]=)%s*([%a_][%w_%.]*)")
    if lhs and rhs and lhs == rhs then
      -- Note: in Lua `x ~= x` is a known NaN check idiom; flag `==` everywhere and `!=` outside NaN checks
      if op == "==" then
        findings[#findings + 1] = {
          lnum = lnum,
          col = (line:find(lhs, 1, true) or 1) - 1,
          severity = vim.diagnostic.severity.WARN,
          code = "suspicious_conditional",
          category = "logic",
          provenance = "deterministic",
          message = string.format("Suspicious self-comparison `%s %s %s` is always true (unless NaN).", lhs, op, rhs),
        }
      end
    end

    -- 3. Accidental assignment inside `if (...)` in C/JS/Python-like syntax
    if ft == "javascript" or ft == "typescript" or ft == "c" or ft == "cpp" then
      local cond_var = code_only:match("^%s*if%s*%(([%a_][%w_]*)%s*=%s*[^=]")
      if cond_var then
        findings[#findings + 1] = {
          lnum = lnum,
          col = (line:find("=", 1, true) or 1) - 1,
          severity = vim.diagnostic.severity.WARN,
          code = "assignment_in_condition",
          category = "logic",
          provenance = "deterministic",
          message = string.format("Suspicious single `=` assignment to `%s` inside `if` condition.", cond_var),
        }
      end
    end

    -- 4. Security pattern checks (runs in standard and deep modes, plus high-signal secret checks)
    if intensity ~= "minimal" then
      if
        (ft == "javascript" or ft == "typescript" or ft == "python") and code_only:match("[^%w_%.\"']eval%s*%(")
        or code_only:match("^%s*eval%s*%(")
      then
        findings[#findings + 1] = {
          lnum = lnum,
          col = (line:find("eval", 1, true) or 1) - 1,
          severity = vim.diagnostic.severity.WARN,
          code = "security_eval",
          category = "security",
          provenance = "deterministic",
          message = "Security risk: dynamic `eval(...)` executes arbitrary code if input is untrusted.",
        }
      end

      if ft == "lua" and (code_only:match("os%.execute%s*%([^%)]*%.%.") or code_only:match("io%.popen%s*%([^%)]*%.%.")) then
        findings[#findings + 1] = {
          lnum = lnum,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          code = "security_shell_concat",
          category = "security",
          provenance = "deterministic",
          message = "Security risk: string concatenation inside shell command risks command injection; prefer `vim.system({...})` argument arrays.",
        }
      end

      if ft == "python" and code_only:match("subprocess%.[%w_]+%b()") and code_only:match("shell%s*=%s*True") then
        findings[#findings + 1] = {
          lnum = lnum,
          col = (line:find("shell", 1, true) or 1) - 1,
          severity = vim.diagnostic.severity.WARN,
          code = "security_shell_true",
          category = "security",
          provenance = "deterministic",
          message = "Security risk: `subprocess` with `shell=True` can enable shell injection.",
        }
      end

      local _, secret_hits = privacy.redact_secrets(line)
      if secret_hits > 0 then
        findings[#findings + 1] = {
          lnum = lnum,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          code = "hardcoded_secret",
          category = "security",
          provenance = "deterministic",
          message = "Potential hardcoded secret or credential detected in source buffer.",
        }
      end
    end

    -- 5. Deep mode: excessive nesting complexity
    if intensity == "deep" and code_only:match("%S") then
      local leading = line:match("^(%s*)") or ""
      local level = indent_unit == "\t" and #leading or math.floor(#leading / math.max(1, indent_width))
      if level >= 6 then
        findings[#findings + 1] = {
          lnum = lnum,
          col = #leading,
          severity = vim.diagnostic.severity.HINT,
          code = "deep_nesting",
          category = "complexity",
          provenance = "deterministic",
          message = string.format("Deep nesting (%d levels); consider early returns or helper extraction.", level),
        }
      end
    end
  end

  -- 6. Unused bound imports (when symbol occurs only once in the whole buffer — at the import line itself)
  for _, imp in ipairs(bound_imports) do
    if (token_counts[imp.sym] or 0) <= 1 then
      findings[#findings + 1] = {
        lnum = imp.lnum,
        col = 0,
        severity = vim.diagnostic.severity.HINT,
        code = "unused_import",
        category = "unused",
        provenance = "deterministic",
        message = string.format("Imported symbol `%s` appears unused in this buffer.", imp.sym),
        replacement = "",
      }
    end
  end

  -- 7. Unused local bindings (standard / deep modes)
  if intensity ~= "minimal" then
    for _, def in ipairs(local_defs) do
      if (token_counts[def.sym] or 0) <= 1 then
        findings[#findings + 1] = {
          lnum = def.lnum,
          col = 0,
          severity = vim.diagnostic.severity.HINT,
          code = "unused_local",
          category = "unused",
          provenance = "deterministic",
          message = string.format("Local variable `%s` is assigned but never referenced.", def.sym),
        }
      end
    end
  end

  return findings
end

---Check whether Lua blocks in `lines` have more openers than `end` keywords.
---@param lines string[]
---@return boolean has_unclosed
local function has_unclosed_lua_block(lines)
  local depth = 0
  for _, l in ipairs(lines) do
    local clean = strip_line_comment(l, "lua")
    for _ in clean:gmatch("%f[%a]function%f[%A]") do
      depth = depth + 1
    end
    for _ in clean:gmatch("%f[%a]then%f[%A]") do
      depth = depth + 1
    end
    for _ in clean:gmatch("%f[%a]do%f[%A]") do
      depth = depth + 1
    end
    for _ in clean:gmatch("%f[%a]repeat%f[%A]") do
      depth = depth + 1
    end
    for _ in clean:gmatch("%f[%a]end%f[%A]") do
      depth = depth - 1
    end
    for _ in clean:gmatch("%f[%a]until%f[%A]") do
      depth = depth - 1
    end
  end
  return depth > 0
end

---Parse parameter names from a function signature line.
---@param sig_line string?
---@return string[]
local function extract_params(sig_line)
  if not sig_line then
    return {}
  end
  local inside = sig_line:match("%(([^%)]*)%)")
  if not inside then
    return {}
  end
  local params = {}
  for raw in inside:gmatch("[^,]+") do
    local name = util.trim(raw):match("^([%a_][%w_]*)")
    if name and name ~= "self" and name ~= "cls" then
      params[#params + 1] = name
    end
  end
  return params
end

---Produce an ultra-fast (<0.2ms) deterministic micro-completion when obvious syntactic structure
---or local symbol continuation applies. Used both before AI and as offline fallback.
---@param ctx { lines: string[], row: integer, col: integer, filetype: string, allow_identifier_fallback?: boolean }
---@return string? suggestion
---@return "structural"|"identifier"? kind
function M.suggest_micro_completion(ctx)
  local lines = ctx.lines or {}
  local row = ctx.row or 1 -- 1-indexed
  local col = ctx.col or 0 -- 0-indexed
  local ft = ctx.filetype or ""
  local line = lines[row] or ""
  local before = line:sub(1, col)
  local after = line:sub(col + 1)
  local indent = line:match("^(%s*)") or ""
  local unit = M.detect_indent(nil, lines)

  -- Structural completions only when cursor is at end of non-whitespace on the line
  if util.trim(after) == "" then
    if ft == "lua" then
      -- Doc annotation scaffold above a Lua function
      if before:match("^%s*%-%-%-$") then
        local next_line = lines[row + 1] or ""
        if next_line:match("function") then
          local params = extract_params(next_line)
          if #params > 0 then
            local doc_lines = { " TODO: describe function" }
            for _, p in ipairs(params) do
              doc_lines[#doc_lines + 1] = indent .. "---@param " .. p .. " any"
            end
            return table.concat(doc_lines, "\n"), "structural"
          end
        end
      end

      -- Module return `ret` -> `urn M` at end of file when `local M = {}` exists
      if row == #lines and before:match("^ret$") then
        for i = 1, math.min(row, 20) do
          if (lines[i] or ""):match("^%s*local%s+M%s*=%s*{") then
            return "urn M", "structural"
          end
        end
      end

      -- Unclosed Lua block scaffold (`if ... then`, `for ... do`, `function(...)`)
      if
        (
          before:match("^%s*if%s+.+%s+then$")
          or before:match("^%s*for%s+.+%s+do$")
          or before:match("^%s*while%s+.+%s+do$")
          or before:match("^%s*local%s+function%s+[%w_]+%b()$")
          or before:match("^%s*function%s+[%w_%.:]+%b()$")
        ) and has_unclosed_lua_block(lines)
      then
        return "\n" .. indent .. unit .. "\n" .. indent .. "end", "structural"
      end
    elseif ft == "python" then
      if before:match("^if __name__$") then
        return ' == "__main__":\n' .. unit .. "main()", "structural"
      end
      if before:match("^%s*\"\"\"$") and row > 1 and (lines[row - 1] or ""):match("^%s*def%s+") then
        local params = extract_params(lines[row - 1])
        local doc = { "Summary." }
        if #params > 0 then
          doc[#doc + 1] = ""
          doc[#doc + 1] = indent .. "Args:"
          for _, p in ipairs(params) do
            doc[#doc + 1] = indent .. unit .. p .. ": Description."
          end
        end
        doc[#doc + 1] = indent .. '"""'
        return table.concat(doc, "\n"), "structural"
      end
    elseif ft == "go" then
      if before:match("^%s*if%s+err%s*!=%s*nil%s*{$") then
        return "\n" .. indent .. unit .. "return err\n" .. indent .. "}", "structural"
      end
    elseif ft == "javascript" or ft == "typescript" then
      if before:match("^%s*/%*%*$") then
        local next_line = lines[row + 1] or ""
        if next_line:match("function%s+") or next_line:match("=>") then
          local params = extract_params(next_line)
          local doc = { "" }
          for _, p in ipairs(params) do
            doc[#doc + 1] = indent .. " * @param {*} " .. p
          end
          doc[#doc + 1] = indent .. " */"
          return table.concat(doc, "\n"), "structural"
        end
      end
    end
  end

  -- Offline / deterministic identifier continuation fallback when explicitly allowed
  if ctx.allow_identifier_fallback then
    local prefix = before:match("([%a_][%w_]*)$")
    local next_ch = after:sub(1, 1)
    if prefix and #prefix >= 3 and (next_ch == "" or not next_ch:match("[%w_]")) then
      local best = nil
      -- Search nearest lines outward from cursor for matching identifiers
      local max_dist = math.min(#lines, 120)
      for dist = 1, max_dist do
        for _, r in ipairs({ row - dist, row + dist }) do
          if r >= 1 and r <= #lines and r ~= row then
            local scan = strip_line_comment(lines[r], ft)
            for cand in scan:gmatch("[%a_][%w_]*") do
              if #cand > #prefix and cand:sub(1, #prefix) == prefix then
                best = cand:sub(#prefix + 1)
                break
              end
            end
            if best then
              break
            end
          end
        end
        if best then
          return best, "identifier"
        end
      end
    end
  end

  return nil, nil
end

return M
