---@mod assistit.diagnostics.quality Proactive multi-stage deterministic code quality engine
local buffer_intel = require("assistit.deterministic.buffer_intel")
local index = require("assistit.context.index")
local transforms = require("assistit.deterministic.transforms")
local util = require("assistit.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("assistit_quality")
M._augroup = nil
M._pause_timer = nil
M._latest_findings = {} -- bufnr -> AssistItFinding[]

---Collect line numbers (1-indexed) that already have diagnostics from external LSP/linters.
---@param bufnr integer
---@return table<integer, boolean>
local function external_diagnostic_lines(bufnr)
  local occupied = {}
  local ok, all = pcall(vim.diagnostic.get, bufnr)
  if not ok or not all then
    return occupied
  end
  for _, d in ipairs(all) do
    if d.namespace ~= M.ns and type(d.lnum) == "number" then
      occupied[d.lnum + 1] = true
    end
  end
  return occupied
end

---Run deterministic quality analysis on `bufnr` at the requested `intensity` and publish non-intrusive hints.
---@param bufnr integer
---@param intensity? "minimal"|"standard"|"deep"
---@return AssistItFinding[]
function M.run_buffer(bufnr, intensity)
  local cfg = require("assistit.config").get()
  if not cfg.enabled or not cfg.quality or not cfg.quality.enabled then
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.diagnostic.reset(M.ns, bufnr)
    end
    return {}
  end

  if not util.is_editable_buffer(bufnr, cfg.ignore_buftypes, cfg.ignore_filetypes) then
    return {}
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count > 4000 and intensity == "minimal" then
    return M._latest_findings[bufnr] or {}
  end

  local ft = vim.bo[bufnr].filetype or ""
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local findings = buffer_intel.analyze_lines(lines, {
    filetype = ft,
    intensity = intensity or cfg.quality.intensity or "minimal",
  })

  local ext_lines = external_diagnostic_lines(bufnr)
  local diags = {}
  local filtered = {}

  for _, f in ipairs(findings) do
    -- Avoid duplicating unused/lint hints on lines already covered by an active LSP server
    local skip = ext_lines[f.lnum] and (f.category == "unused" or f.category == "style")
    if not skip then
      filtered[#filtered + 1] = f
      diags[#diags + 1] = {
        lnum = math.max(0, f.lnum - 1),
        col = math.max(0, f.col or 0),
        severity = f.severity,
        source = "assistit:deterministic",
        code = f.code,
        message = f.message,
        user_data = { assistit_finding = f },
      }
    end
  end

  M._latest_findings[bufnr] = filtered
  if cfg.diagnostics and cfg.diagnostics.enabled ~= false then
    vim.diagnostic.set(M.ns, bufnr, diags, {
      virtual_text = cfg.diagnostics.virtual_indicator ~= false and {
        spacing = 2,
        prefix = "·",
      } or false,
      signs = false, -- Keep sign column uncluttered; LSP owns primary gutter signs
      underline = true,
    })
  end

  return filtered
end

---Retrieve cached deterministic findings for `bufnr` (or compute if absent).
---@param bufnr integer
---@return AssistItFinding[]
function M.get_findings(bufnr)
  return M._latest_findings[bufnr] or M.run_buffer(bufnr)
end

function M.setup(cfg)
  M.teardown()
  if not cfg.quality or not cfg.quality.enabled then
    return
  end

  M._augroup = vim.api.nvim_create_augroup("AssistItQuality", { clear = true })

  if cfg.quality.on_type then
    -- O(1) cheap single-line check on InsertLeave (never scans whole buffer while typing)
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = M._augroup,
      callback = function(ev)
        local cur_cfg = require("assistit.config").get()
        if not cur_cfg.enabled or not util.is_editable_buffer(ev.buf, cur_cfg.ignore_buftypes, cur_cfg.ignore_filetypes) then
          return
        end
        local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1
        local one_line = vim.api.nvim_buf_get_lines(ev.buf, row0, row0 + 1, false)
        local quick = buffer_intel.analyze_lines(one_line, {
          filetype = vim.bo[ev.buf].filetype or "",
          intensity = "minimal",
        })
        if #quick > 0 then
          M.run_buffer(ev.buf, "minimal")
        end
      end,
      desc = "assistit: O(1) single-line check after insert",
    })
  end

  if cfg.quality.on_pause then
    M._pause_timer = util.new_timer()
    vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
      group = M._augroup,
      callback = function(ev)
        if M._pause_timer then
          M._pause_timer:start(cfg.quality.pause_ms or 900, function()
            if vim.api.nvim_buf_is_valid(ev.buf) then
              M.run_buffer(ev.buf, cfg.quality.intensity)
            end
          end)
        end
      end,
      desc = "assistit: lightweight pause quality check",
    })
  end

  if cfg.quality.on_save then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = M._augroup,
      callback = function(ev)
        local cur_cfg = require("assistit.config").get()
        if not cur_cfg.enabled then
          return
        end
        -- Safety rule: automatic edits ONLY run for deterministic safe whitespace cleanup when explicitly enabled
        if
          (cur_cfg.deterministic and cur_cfg.deterministic.auto_cleanup_whitespace)
          or (cur_cfg.diagnostics and cur_cfg.diagnostics.automatic_fixes)
        then
          transforms.strip_trailing_whitespace(ev.buf)
        end
        M.run_buffer(ev.buf, cur_cfg.quality and cur_cfg.quality.intensity or "standard")
        local name = vim.api.nvim_buf_get_name(ev.buf)
        if name ~= "" then
          index.refresh_file(name, cur_cfg)
        end
      end,
      desc = "assistit: post-save quality & incremental index update",
    })
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = M._augroup,
    callback = function(ev)
      M._latest_findings[ev.buf] = nil
    end,
  })
end

function M.teardown()
  if M._pause_timer then
    M._pause_timer:close()
    M._pause_timer = nil
  end
  if M._augroup then
    pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
    M._augroup = nil
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      pcall(vim.diagnostic.reset, M.ns, b)
    end
  end
  M._latest_findings = {}
end

return M
