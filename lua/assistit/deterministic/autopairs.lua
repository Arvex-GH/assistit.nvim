---@mod assistit.deterministic.autopairs Lightweight cursor-aware pair completion
local util = require("assistit.util")

local M = {}

local OPEN_TO_CLOSE = {
  ["("] = ")",
  ["["] = "]",
  ["{"] = "}",
}

local CLOSE_CHARS = {
  [")"] = true,
  ["]"] = true,
  ["}"] = true,
}

local QUOTES = {
  ['"'] = true,
  ["'"] = true,
  ["`"] = true,
}

M._installed = false
M._mapped_keys = {}

---Detect whether another dedicated autopairs plugin is already loaded.
---@return boolean
function M.has_external_autopairs()
  local known = {
    "nvim-autopairs",
    "mini.pairs",
    "ultimate-autopair",
    "autoclose",
    "pear-tree",
  }
  for _, mod in ipairs(known) do
    if package.loaded[mod] then
      return true
    end
  end
  if vim.g.AutoPairsLoaded or vim.g.lexima_loaded then
    return true
  end
  return false
end

---Count unescaped occurrences of `quote` in `str`.
---@param str string
---@param quote string
---@return integer
local function count_unescaped(str, quote)
  local count = 0
  local escaped = false
  for i = 1, #str do
    local ch = str:sub(i, i)
    if escaped then
      escaped = false
    elseif ch == "\\" then
      escaped = true
    elseif ch == quote then
      count = count + 1
    end
  end
  return count
end

---Compute the insert-mode key sequence for a typed pair character at `(line, col0)`.
---Pure helper so both keymaps and unit tests can evaluate pair logic directly.
---@param ch string
---@param line string Current buffer line
---@param col0 integer 0-indexed byte column of cursor
---@param filetype? string
---@return string keys_or_literal, boolean is_special
function M.compute_action(ch, line, col0, filetype)
  local before = line:sub(1, col0)
  local after = line:sub(col0 + 1)
  local prev_char = col0 > 0 and line:sub(col0, col0) or ""
  local next_char = after:sub(1, 1)

  -- Never interfere if previous char is a backslash escape
  if prev_char == "\\" then
    return ch, false
  end

  -- Step over closing brackets when already present right under cursor
  if CLOSE_CHARS[ch] then
    if next_char == ch then
      return "<Right>", true
    end
    return ch, false
  end

  -- Symmetric quotes
  if QUOTES[ch] then
    if next_char == ch then
      return "<Right>", true
    end
    -- Don't auto-pair apostrophe after word chars (contractions, Rust lifetimes `'a`)
    if ch == "'" and (prev_char:match("[%w_]") or filetype == "rust") then
      return ch, false
    end
    -- Don't auto-pair right before alphanumeric characters or another quote
    if next_char ~= "" and next_char:match("[%w_\"'`]") then
      return ch, false
    end
    -- Don't auto-pair if we're closing an already-open quote on this line
    if count_unescaped(before, ch) % 2 == 1 then
      return ch, false
    end
    return ch .. ch .. "<Left>", true
  end

  -- Opening brackets
  local close = OPEN_TO_CLOSE[ch]
  if close then
    if next_char ~= "" and next_char:match("[%w_]") then
      return ch, false
    end
    return ch .. close .. "<Left>", true
  end

  return ch, false
end

---Install lightweight global insert-mode pair mappings, skipping any key already mapped by user.
---@param cfg table
function M.setup(cfg)
  M.teardown()
  local det = cfg.deterministic or {}
  if not det.enabled then
    return
  end
  local mode_setting = det.autopairs
  if mode_setting == false then
    return
  end
  if mode_setting == "auto" and M.has_external_autopairs() then
    return
  end

  local chars = { "(", ")", "[", "]", "{", "}", '"', "'", "`" }
  for _, ch in ipairs(chars) do
    local existing = vim.fn.maparg(ch, "i", false, true)
    if not existing or vim.tbl_isempty(existing) then
      vim.keymap.set("i", ch, function()
        local cur_cfg = require("assistit.config").get()
        if not cur_cfg.enabled or not cur_cfg.deterministic.enabled then
          return ch
        end
        local bufnr = vim.api.nvim_get_current_buf()
        if not util.is_editable_buffer(bufnr, cur_cfg.ignore_buftypes, cur_cfg.ignore_filetypes) then
          return ch
        end
        local pos = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_get_current_line()
        local out, is_special = M.compute_action(ch, line, pos[2], vim.bo[bufnr].filetype)
        if is_special then
          return vim.api.nvim_replace_termcodes(out, true, false, true)
        end
        return out
      end, { expr = true, noremap = true, silent = true, desc = "assistit: deterministic autopair " .. ch })
      M._mapped_keys[#M._mapped_keys + 1] = ch
    end
  end
  M._installed = true
end

function M.teardown()
  for _, ch in ipairs(M._mapped_keys) do
    pcall(vim.keymap.del, "i", ch)
  end
  M._mapped_keys = {}
  M._installed = false
end

return M
