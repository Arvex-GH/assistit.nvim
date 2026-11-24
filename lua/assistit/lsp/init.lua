---@mod assistit.lsp Layer B integration with Neovim built-in LSP, diagnostics, and completion menus
local treesitter = require("assistit.lsp.treesitter")

local M = {
  treesitter = treesitter,
}

---Check if any completion menu (native pum, nvim-cmp, or blink.cmp) is currently open.
---Never calls `require()` on uninstalled plugins; inspects `package.loaded` safely.
---@return boolean
function M.is_popup_visible()
  if vim.fn.pumvisible() == 1 then
    return true
  end

  local cmp = package.loaded["cmp"]
  if type(cmp) == "table" and type(cmp.visible) == "function" then
    local ok, vis = pcall(cmp.visible)
    if ok and vis then
      return true
    end
  end

  local blink = package.loaded["blink.cmp"]
  if type(blink) == "table" and type(blink.is_visible) == "function" then
    local ok, vis = pcall(blink.is_visible)
    if ok and vis then
      return true
    end
  end

  return false
end

---List names of LSP clients currently attached to `bufnr`.
---@param bufnr integer
---@return string[]
function M.get_client_names(bufnr)
  if not vim.lsp or not vim.lsp.get_clients then
    return {}
  end
  local ok, clients = pcall(vim.lsp.get_clients, { bufnr = bufnr })
  if not ok or not clients then
    return {}
  end
  local names = {}
  for _, c in ipairs(clients) do
    names[#names + 1] = c.name
  end
  return names
end

---Fetch diagnostics on or near `row0` from `vim.diagnostic`.
---@param bufnr integer
---@param row0? integer 0-indexed line; nil fetches entire buffer
---@param min_severity? integer e.g. vim.diagnostic.severity.WARN
---@return table[]
function M.get_diagnostics(bufnr, row0, min_severity)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  local opts = {}
  if row0 ~= nil then
    opts.lnum = row0
  end
  if min_severity ~= nil then
    -- In vim.diagnostic, ERROR = 1, WARN = 2, INFO = 3, HINT = 4 (smaller integer = higher severity)
    opts.severity = { min = min_severity }
  end
  local ok, diags = pcall(vim.diagnostic.get, bufnr, opts)
  if not ok or not diags then
    return {}
  end
  -- Exclude assistit's own hint namespace when querying external LSP/linter diagnostics if needed
  return diags
end

---Query attached LSP clients asynchronously for available code actions at `(row0, col0)`.
---@param bufnr integer
---@param row0 integer 0-indexed row
---@param col0 integer 0-indexed col
---@param callback fun(actions: table[])
function M.query_code_actions(bufnr, row0, col0, callback)
  local clients = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = bufnr }) or {}
  local capable = {}
  for _, client in ipairs(clients) do
    if client.supports_method and client:supports_method("textDocument/codeAction") then
      capable[#capable + 1] = client
    end
  end

  if #capable == 0 then
    callback({})
    return
  end

  local line_diags = M.get_diagnostics(bufnr, row0)
  local lsp_diags = {}
  for _, d in ipairs(line_diags) do
    if d.user_data and d.user_data.lsp then
      lsp_diags[#lsp_diags + 1] = d.user_data.lsp
    end
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    range = {
      start = { line = row0, character = col0 },
      ["end"] = { line = row0, character = col0 },
    },
    context = {
      diagnostics = lsp_diags,
    },
  }

  vim.lsp.buf_request_all(bufnr, "textDocument/codeAction", params, function(results)
    local found = {}
    for client_id, resp in pairs(results or {}) do
      if resp and type(resp.result) == "table" then
        for _, action in ipairs(resp.result) do
          found[#found + 1] = {
            client_id = client_id,
            title = action.title or "Code Action",
            kind = action.kind,
            action = action,
          }
        end
      end
    end
    callback(found)
  end)
end

---Execute an LSP code action returned by `query_code_actions`.
---@param entry { client_id: integer, action: table }
---@param bufnr integer
---@return boolean applied
function M.apply_code_action(entry, bufnr)
  if not entry or not entry.action then
    return false
  end
  local client = vim.lsp.get_client_by_id(entry.client_id)
  local encoding = (client and client.offset_encoding) or "utf-16"
  local action = entry.action

  if action.edit then
    vim.lsp.util.apply_workspace_edit(action.edit, encoding)
  end
  if action.command then
    local cmd = type(action.command) == "table" and action.command or action
    if client then
      client:exec_cmd(cmd, { bufnr = bufnr })
    end
  end
  return true
end

return M
