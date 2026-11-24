---@mod assistit.deterministic.transforms Safe deterministic code cleanup operations
local buffer_intel = require("assistit.deterministic.buffer_intel")

local M = {}

---Strip trailing whitespace across a buffer in a single undoable step.
---@param bufnr? integer
---@return integer modified_lines
function M.strip_trailing_whitespace(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.bo[bufnr].modifiable then
    return 0
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local changed = 0
  local updated = {}
  for i, line in ipairs(lines) do
    local stripped = line:gsub("[ \t]+$", "")
    if stripped ~= line then
      changed = changed + 1
    end
    updated[i] = stripped
  end
  if changed > 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, updated)
  end
  return changed
end

---Remove exact duplicate import lines detected deterministically.
---@param bufnr? integer
---@return integer removed_count
function M.remove_duplicate_imports(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.bo[bufnr].modifiable then
    return 0
  end
  local ft = vim.bo[bufnr].filetype
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local seen = {}
  local kept = {}
  local removed = 0

  for _, line in ipairs(lines) do
    local key = buffer_intel.parse_import_line(line, ft)
    if key and seen[key] then
      removed = removed + 1
    else
      if key then
        seen[key] = true
      end
      kept[#kept + 1] = line
    end
  end

  if removed > 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, kept)
  end
  return removed
end

---Format buffer using attached LSP formatter if available, falling back to safe whitespace cleanup.
---@param bufnr? integer
---@return boolean used_lsp, integer fallback_changes
function M.format_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = bufnr }) or {}
  for _, client in ipairs(clients) do
    if client.supports_method and client:supports_method("textDocument/formatting") then
      vim.lsp.buf.format({ bufnr = bufnr, async = true })
      return true, 0
    end
  end
  local count = M.strip_trailing_whitespace(bufnr)
  return false, count
end

return M
