---@mod assistit.completion.progressive Full and incremental (word/line) suggestion acceptance
local ghost = require("assistit.completion.ghost")
local personalization = require("assistit.personalization")

local M = {}

---Last buffer changedtick produced by our own acceptance edit so TextChangedI preserves remaining ghost text.
M.last_accepted_tick = { bufnr = -1, tick = -1 }

---Split `text` into `(first_word_chunk, remaining)`.
---@param text string
---@return string accepted, string remaining
function M.split_next_word(text)
  if not text or text == "" then
    return "", ""
  end

  -- If starting with a newline, consume the newline + indentation + first token on that line
  local nl_chunk = text:match("^(\n[ \t]*[%w_]+)")
    or text:match("^(\n[ \t]*[^%w_%s]+)")
    or text:match("^(\n[ \t]*)")
  if nl_chunk then
    return nl_chunk, text:sub(#nl_chunk + 1)
  end

  -- Otherwise consume optional leading horizontal whitespace + next identifier or punctuation token
  local word_chunk = text:match("^([ \t]*[%w_]+)")
    or text:match("^([ \t]*[^%w_%s]+)")
    or text:match("^([ \t]+)")
  if word_chunk and word_chunk ~= "" then
    return word_chunk, text:sub(#word_chunk + 1)
  end

  return text, ""
end

---Split `text` into `(next_line_chunk, remaining)`.
---@param text string
---@return string accepted, string remaining
function M.split_next_line(text)
  if not text or text == "" then
    return "", ""
  end

  local first_nl = text:find("\n", 1, true)
  if not first_nl then
    return text, ""
  end

  -- If there is inline text before the first `\n`, accept up to that `\n` first
  if first_nl > 1 then
    return text:sub(1, first_nl - 1), text:sub(first_nl)
  end

  -- Text starts with `\n`: accept `\n` plus the entire next line up to the following `\n`
  local second_nl = text:find("\n", 2, true)
  if not second_nl then
    return text, ""
  end
  return text:sub(1, second_nl - 1), text:sub(second_nl)
end

---Compute overlap length between the end of `chunk` and the beginning of `line_after`.
---@param chunk string
---@param line_after string
---@return integer overlap_bytes
function M.compute_suffix_overlap(chunk, line_after)
  if chunk == "" or line_after == "" then
    return 0
  end
  local max_len = math.min(#chunk, #line_after)
  for len = max_len, 1, -1 do
    if chunk:sub(#chunk - len + 1) == line_after:sub(1, len) then
      return len
    end
  end
  return 0
end

---Insert `chunk` at `(row, col)` in `bufnr`, deduplicating any overlap with existing `line_after`
---when completing the final piece of a suggestion.
---@param bufnr integer
---@param winid integer
---@param row integer 1-indexed
---@param col integer 0-indexed
---@param chunk string
---@param remaining string
---@return integer new_row, integer new_col
local function apply_to_buffer(bufnr, winid, row, col, chunk, remaining)
  local row0 = row - 1
  local cur_line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ""
  local col0 = math.min(col, #cur_line)
  local line_after = cur_line:sub(col0 + 1)

  -- When finishing the suggestion, consume any overlapping suffix characters already after cursor
  local end_col0 = col0
  if remaining == "" and line_after ~= "" then
    local overlap = M.compute_suffix_overlap(chunk, line_after)
    if overlap > 0 then
      end_col0 = col0 + overlap
    end
  end

  local insert_lines = vim.split(chunk, "\n", { plain = true })
  vim.api.nvim_buf_set_text(bufnr, row0, col0, row0, end_col0, insert_lines)

  local new_row, new_col
  if #insert_lines == 1 then
    new_row = row
    new_col = col0 + #insert_lines[1]
  else
    new_row = row + #insert_lines - 1
    new_col = #insert_lines[#insert_lines]
  end

  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
    pcall(vim.api.nvim_win_set_cursor, winid, { new_row, new_col })
  end

  M.last_accepted_tick = {
    bufnr = bufnr,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
  }

  return new_row, new_col
end

---Accept active ghost suggestion in mode `"full"`, `"word"`, or `"line"`.
---@param mode? "full"|"word"|"line"
---@return boolean accepted
function M.accept(mode)
  mode = mode or "full"
  local active = ghost.get()
  if not active or active.text == "" then
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  if active.bufnr ~= bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    ghost.clear()
    return false
  end

  local cfg = require("assistit.config").get()
  if (mode == "word" or mode == "line") and cfg.completion and cfg.completion.progressive_accept == false then
    mode = "full"
  end

  local chunk, remaining
  if mode == "word" then
    chunk, remaining = M.split_next_word(active.text)
  elseif mode == "line" then
    chunk, remaining = M.split_next_line(active.text)
  else
    chunk, remaining = active.text, ""
  end

  if chunk == "" then
    ghost.clear()
    return false
  end

  local source = active.source
  local latency_ms = active.latency_ms
  local ft = vim.bo[bufnr].filetype or ""

  local new_row, new_col = apply_to_buffer(bufnr, winid, active.row, active.col, chunk, remaining)
  personalization.record_accepted(ft, chunk, remaining ~= "")

  if remaining ~= "" then
    ghost.show(bufnr, new_row, new_col, remaining, {
      source = source,
      latency_ms = latency_ms,
    })
  else
    ghost.clear()
  end

  return true
end

return M
