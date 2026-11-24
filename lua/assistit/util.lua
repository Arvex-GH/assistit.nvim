---@mod assistit.util Core utilities for assistit.nvim
local M = {}

local uv = vim.uv or vim.loop
local has_bit, bit = pcall(require, "bit")

---High-resolution monotonic timestamp in milliseconds.
---@return number
function M.now_ms()
  if uv and uv.hrtime then
    return uv.hrtime() / 1e6
  end
  return os.clock() * 1000
end

---Fast deterministic 32-bit FNV-1a hash encoded as 8-char hex.
---Avoids cryptographic overhead while providing low-collision cache keys.
---@param str string
---@return string
function M.hash(str)
  if type(str) ~= "string" then
    str = tostring(str or "")
  end
  if has_bit then
    local h = 0x811c9dc5
    for i = 1, #str do
      h = bit.bxor(h, string.byte(str, i))
      h = bit.tobit(h * 0x01000193)
    end
    -- Convert signed 32-bit int from LuaJIT bit ops to unsigned hex
    if h < 0 then
      h = h + 0x100000000
    end
    return string.format("%08x", h)
  end

  local h = 2166136261
  for i = 1, #str do
    h = (h + string.byte(str, i)) % 4294967296
    h = (h * 16777619) % 4294967296
  end
  return string.format("%08x", h)
end

---Split a string into lines, preserving empty lines and stripping trailing \r.
---@param text string
---@return string[]
function M.split_lines(text)
  if text == nil or text == "" then
    return {}
  end
  local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.split(normalized, "\n", { plain = true })
end

---Trim leading and trailing whitespace.
---@param s string
---@return string
function M.trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---Clamp a numeric value between min_val and max_val.
---@param val number
---@param min_val number
---@param max_val number
---@return number
function M.clamp(val, min_val, max_val)
  if val < min_val then
    return min_val
  end
  if val > max_val then
    return max_val
  end
  return val
end

---Check whether a buffer is valid, loaded, and normal/editable for code features.
---@param bufnr integer
---@param ignore_buftypes? table<string, boolean>
---@param ignore_filetypes? table<string, boolean>
---@return boolean
function M.is_editable_buffer(bufnr, ignore_buftypes, ignore_filetypes)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
    return false
  end
  local bt = vim.bo[bufnr].buftype or ""
  if ignore_buftypes and ignore_buftypes[bt] then
    return false
  end
  if bt ~= "" and bt ~= "acwrite" then
    return false
  end
  local ft = vim.bo[bufnr].filetype or ""
  if ignore_filetypes and ignore_filetypes[ft] then
    return false
  end
  return true
end

---Create a reusable libuv timer wrapper that safely schedules callbacks on Neovim's main loop.
---@return { start: fun(self: table, delay_ms: integer, fn: fun()), stop: fun(self: table), close: fun(self: table), is_active: fun(self: table): boolean }
function M.new_timer()
  local handle = uv.new_timer()
  local timer = { _handle = handle }

  function timer:stop()
    if self._handle and not self._handle:is_closing() then
      self._handle:stop()
    end
  end

  function timer:start(delay_ms, fn)
    if not self._handle or self._handle:is_closing() then
      self._handle = uv.new_timer()
    end
    self._handle:stop()
    local wait = math.max(0, math.floor(delay_ms or 0))
    self._handle:start(
      wait,
      0,
      vim.schedule_wrap(function()
        fn()
      end)
    )
  end

  function timer:is_active()
    return self._handle ~= nil and not self._handle:is_closing() and self._handle:is_active()
  end

  function timer:close()
    if self._handle and not self._handle:is_closing() then
      self._handle:stop()
      self._handle:close()
    end
    self._handle = nil
  end

  return timer
end

---Rough token estimation (~4 chars per token for code) without requiring a heavy tokenizer.
---@param text string
---@return integer
function M.estimate_tokens(text)
  if not text or #text == 0 then
    return 0
  end
  return math.ceil(#text / 4)
end

---Truncate lines from the top (keeping lines closest to cursor) within a character budget.
---@param lines string[]
---@param max_chars integer
---@return string text, integer kept_count
function M.tail_within_budget(lines, max_chars)
  if not lines or #lines == 0 or max_chars <= 0 then
    return "", 0
  end
  local acc = {}
  local used = 0
  for i = #lines, 1, -1 do
    local line = lines[i]
    local cost = #line + 1
    if used + cost > max_chars then
      if #acc == 0 then
        table.insert(acc, 1, line:sub(math.max(1, #line - max_chars + 1)))
      end
      break
    end
    table.insert(acc, 1, line)
    used = used + cost
  end
  return table.concat(acc, "\n"), #acc
end

---Truncate lines from the bottom (keeping lines closest after cursor) within a character budget.
---@param lines string[]
---@param max_chars integer
---@return string
function M.head_within_budget(lines, max_chars)
  if not lines or #lines == 0 or max_chars <= 0 then
    return ""
  end
  local acc = {}
  local used = 0
  for i = 1, #lines do
    local line = lines[i]
    local cost = #line + 1
    if used + cost > max_chars then
      if #acc == 0 then
        acc[#acc + 1] = line:sub(1, max_chars)
      end
      break
    end
    acc[#acc + 1] = line
    used = used + cost
  end
  return table.concat(acc, "\n")
end

---Check if an HTTP endpoint points to a loopback / strictly local address.
---@param endpoint string
---@return boolean
function M.is_local_endpoint(endpoint)
  if type(endpoint) ~= "string" or endpoint == "" then
    return false
  end
  local host = endpoint:match("^https?://([^/:%?]+)")
  if not host then
    -- Unix domain socket path
    if endpoint:match("^unix://") or endpoint:sub(1, 1) == "/" then
      return true
    end
    return false
  end
  host = host:lower()
  if
    host == "localhost"
    or host == "127.0.0.1"
    or host == "[::1]"
    or host == "::1"
    or host == "0.0.0.0"
    or host:match("^127%.%d+%.%d+%.%d+$")
  then
    return true
  end
  return false
end

---Normalize filetype or fence tag to canonical programming language identifier.
---@param ft string?
---@return string
function M.filetype_language(ft)
  local map = {
    javascriptreact = "javascript",
    jsx = "javascript",
    js = "javascript",
    mjs = "javascript",
    cjs = "javascript",
    typescriptreact = "typescript",
    tsx = "typescript",
    ts = "typescript",
    sh = "bash",
    zsh = "bash",
    shell = "bash",
    cs = "csharp",
    ["c#"] = "csharp",
    ["c++"] = "cpp",
    cxx = "cpp",
    cc = "cpp",
    hpp = "cpp",
    h = "c",
    py = "python",
    python3 = "python",
    rs = "rust",
    rb = "ruby",
    kt = "kotlin",
    kts = "kotlin",
    ex = "elixir",
    exs = "elixir",
    hs = "haskell",
    ml = "ocaml",
    yml = "yaml",
    md = "markdown",
    viml = "vim",
    tf = "terraform",
    ps1 = "powershell",
  }
  if not ft or ft == "" then
    return "text"
  end
  local lower = ft:lower()
  return map[lower] or lower
end

---Infer programming language from shebang or syntax tokens when editing an unnamed/unsaved buffer (`filetype == ""`).
---@param lines string[]?
---@return string language -- Returns "text" when ambiguous
function M.infer_language_from_lines(lines)
  if not lines or #lines == 0 then
    return "text"
  end

  local first = M.trim(lines[1] or "")
  if first:sub(1, 2) == "#!" then
    local lower_shebang = first:lower()
    if lower_shebang:find("python", 1, true) then
      return "python"
    elseif lower_shebang:find("node", 1, true) or lower_shebang:find("deno", 1, true) or lower_shebang:find("bun", 1, true) then
      return "javascript"
    elseif lower_shebang:find("lua", 1, true) then
      return "lua"
    elseif lower_shebang:find("ruby", 1, true) then
      return "ruby"
    elseif lower_shebang:find("bash", 1, true) or lower_shebang:find("/sh") or lower_shebang:find("zsh", 1, true) then
      return "bash"
    end
  end

  local scores = {}
  local function bump(lang, pts)
    scores[lang] = (scores[lang] or 0) + pts
  end

  local max_scan = math.min(#lines, 40)
  for i = 1, max_scan do
    local l = M.trim(lines[i] or "")
    if l ~= "" then
      -- Lua
      if l:match("^local%s+function%s+") or l:match("^local%s+[%w_]+%s*=%s*require") or l:match("%f[%a]elseif%f[%A]") then
        bump("lua", 4)
      elseif l:match("^local%s+[%w_]+%s*=") or l:match("%s+then$") or l == "end" then
        bump("lua", 2)
      end

      -- Python
      if l:match("^def%s+[%w_]+%s*%b()%s*:") or l:match("^async%s+def%s+[%w_]+") or l:match("^from%s+[%w_%.]+%s+import%s+") then
        bump("python", 4)
      elseif l:match("^elif%s+.+:") or l:match("^class%s+[%w_]+.*:$") or l:match("^if%s+__name__%s*==") then
        bump("python", 3)
      end

      -- Rust
      if l:match("^pub%s+fn%s+") or l:match("^fn%s+[%w_]+%s*%(") or l:match("^let%s+mut%s+") or l:match("println!%(") then
        bump("rust", 4)
      elseif l:match("^use%s+[%w_:]+;") or l:match("^impl[%s<]") then
        bump("rust", 3)
      end

      -- Go
      if l:match("^package%s+[%w_]+$") or l:match("^func%s+[%w_%(]") then
        bump("go", 4)
      elseif l:find(":=", 1, true) or l:match("^import%s+%($") then
        bump("go", 2)
      end

      -- C / C++
      if l:match("^#include%s*<") or l:match("^#include%s*\"") then
        if l:find(".h>", 1, true) or l:find("stdio.h", 1, true) or l:find("stdlib.h", 1, true) then
          bump("c", 3)
        else
          bump("cpp", 4)
        end
      end
      if l:find("std::", 1, true) or l:match("^namespace%s+[%w_]+") or l:match("^template%s*<") then
        bump("cpp", 4)
      end

      -- TypeScript / JavaScript
      if l:match("^export%s+interface%s+") or l:match("^interface%s+[%w_]+%s*{") or l:match("^type%s+[%w_]+%s*=") then
        bump("typescript", 4)
      elseif l:match(":%s*string%f[%A]") or l:match(":%s*number%f[%A]") or l:match(":%s*boolean%f[%A]") then
        bump("typescript", 3)
      end
      if l:match("^import%s+.+%s+from%s+[\"']") or l:match("^export%s+default%s+") or l:match("^const%s+[%w_$]+%s*=") then
        bump("javascript", 2)
        bump("typescript", 2)
      elseif l:find("console.log(", 1, true) or l:find("=>", 1, true) then
        bump("javascript", 2)
      end

      -- SQL
      local upper = l:upper()
      if upper:match("^SELECT%s+.+%s+FROM%s+") or upper:match("^CREATE%s+TABLE%s+") or upper:match("^INSERT%s+INTO%s+") then
        bump("sql", 4)
      end
    end
  end

  local best_lang = "text"
  local best_score = 1 -- Require >= 2 points so plain prose stays "text"
  for lang, sc in pairs(scores) do
    if sc > best_score or (sc == best_score and lang == "typescript" and best_lang == "javascript") then
      best_score = sc
      best_lang = lang
    end
  end
  return best_lang
end

return M
