---@mod assistit.ui.preview Lightweight floating diff & explanation preview windows
local util = require("assistit.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("assistit_preview")

---@type { win: integer, buf: integer, target_buf: integer, start_row0: integer, end_row0: integer, new_lines: string[], on_accept?: fun(), on_reject?: fun(), on_explain?: fun() }?
M.active_proposal = nil

---Close any currently open preview window cleanly.
function M.close()
  if M.active_proposal then
    local win = M.active_proposal.win
    local buf = M.active_proposal.buf
    M.active_proposal = nil
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---Format provenance label so users always know whether an insight is confirmed or an AI hypothesis.
---@param provenance? "confirmed"|"lsp"|"deterministic"|"ai_hypothesis"
---@return string label, string hl_group
function M.provenance_badge(provenance)
  if provenance == "confirmed" or provenance == "lsp" then
    return "[Confirmed LSP Diagnostic]", "AssistItConfirmed"
  elseif provenance == "deterministic" then
    return "[Deterministic Static Check]", "AssistItHint"
  end
  return "[AI Hypothesis — Unverified, Review Before Applying]", "AssistItHypothesis"
end

---Compute floating window geometry bounded safely to terminal columns/lines.
---@param lines string[]
---@return integer width, integer height, integer row, integer col
local function compute_geometry(lines)
  local max_line_len = 36
  for _, l in ipairs(lines) do
    if #l > max_line_len then
      max_line_len = #l
    end
  end
  local ui_cols = math.max(40, vim.o.columns or 80)
  local ui_lines = math.max(12, vim.o.lines or 24)

  local width = util.clamp(max_line_len + 4, 42, math.max(42, math.floor(ui_cols * 0.8)))
  local height = util.clamp(#lines, 4, math.max(6, math.floor(ui_lines * 0.65)))
  local row = math.max(1, math.floor((ui_lines - height) / 2) - 1)
  local col = math.max(1, math.floor((ui_cols - width) / 2))
  return width, height, row, col
end

---Open a read-only floating information/explanation window (`q` or `<Esc>` closes).
---@param opts { title?: string, provenance?: string, lines: string[]|string }
---@return integer buf, integer win
function M.open_info(opts)
  M.close()
  local cfg = require("assistit.config").get()
  local border = (cfg.ui and cfg.ui.border) or "rounded"

  local body_lines = type(opts.lines) == "string" and util.split_lines(opts.lines) or vim.deepcopy(opts.lines or {})
  local badge, _ = M.provenance_badge(opts.provenance)

  local content = {
    badge,
    string.rep("─", math.min(60, math.max(24, #badge))),
  }
  for _, l in ipairs(body_lines) do
    content[#content + 1] = l
  end
  content[#content + 1] = ""
  content[#content + 1] = "[q / <Esc>] Close"

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.bo[buf].modifiable = false

  local width, height, row, col = compute_geometry(content)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = border,
    title = " " .. (opts.title or "AssistIt") .. " ",
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local close_fn = function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.keymap.set("n", "q", close_fn, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close_fn, { buffer = buf, silent = true, nowait = true })

  M.active_proposal = {
    win = win,
    buf = buf,
    target_buf = -1,
    start_row0 = 0,
    end_row0 = 0,
    new_lines = {},
  }

  return buf, win
end

---Compute unified diff lines between `old_lines` and `new_lines`.
---@param old_lines string[]
---@param new_lines string[]
---@return string[]
function M.build_diff_lines(old_lines, new_lines)
  local old_str = table.concat(old_lines, "\n") .. "\n"
  local new_str = table.concat(new_lines, "\n") .. "\n"
  if vim.diff then
    local ok, diff_text = pcall(vim.diff, old_str, new_str, {
      result_type = "unified",
      ctxlen = 2,
    })
    if ok and type(diff_text) == "string" and util.trim(diff_text) ~= "" then
      return util.split_lines(util.trim(diff_text))
    end
  end

  local fallback = {}
  for _, l in ipairs(old_lines) do
    fallback[#fallback + 1] = "- " .. l
  end
  for _, l in ipairs(new_lines) do
    fallback[#fallback + 1] = "+ " .. l
  end
  return fallback
end

---Accept the currently displayed proposal, applying changes in one undoable buffer step.
---@return boolean applied
function M.accept_active()
  local prop = M.active_proposal
  if not prop or prop.target_buf < 0 then
    return false
  end
  local tbuf = prop.target_buf
  local s0 = prop.start_row0
  local e0 = prop.end_row0
  local replacement = prop.new_lines
  local cb = prop.on_accept

  M.close()

  if not vim.api.nvim_buf_is_valid(tbuf) or not vim.bo[tbuf].modifiable then
    vim.notify("[assistit] Target buffer is no longer modifiable.", vim.log.levels.WARN)
    return false
  end

  vim.api.nvim_buf_set_lines(tbuf, s0, e0, false, replacement)
  if cb then
    cb()
  end
  return true
end

---Reject and close the currently displayed proposal without modifying any buffer.
---@return boolean rejected
function M.reject_active()
  local prop = M.active_proposal
  if not prop then
    return false
  end
  local cb = prop.on_reject
  M.close()
  if cb then
    cb()
  end
  return true
end

---Open an interactive review/diff window for a proposed code change (`[Accept] [Reject] [Explain]`).
---@param opts { title?: string, provenance?: "confirmed"|"lsp"|"deterministic"|"ai_hypothesis", summary?: string, target_buf: integer, start_row0: integer, end_row0: integer, new_lines: string[], on_accept?: fun(), on_reject?: fun(), on_explain?: fun() }
---@return integer buf, integer win
function M.open_proposal(opts)
  M.close()
  local cfg = require("assistit.config").get()
  local border = (cfg.ui and cfg.ui.border) or "rounded"

  local old_lines = vim.api.nvim_buf_get_lines(opts.target_buf, opts.start_row0, opts.end_row0, false)
  local diff_lines = M.build_diff_lines(old_lines, opts.new_lines)
  local badge, badge_hl = M.provenance_badge(opts.provenance)

  local display = { badge }
  if opts.summary and opts.summary ~= "" then
    for _, sl in ipairs(util.split_lines(opts.summary)) do
      display[#display + 1] = sl
    end
  end
  display[#display + 1] = string.rep("─", 48)
  local diff_start_idx = #display + 1
  for _, dl in ipairs(diff_lines) do
    display[#display + 1] = dl
  end
  local diff_end_idx = #display
  display[#display + 1] = string.rep("─", 48)

  local controls = "[a / <CR>] Accept    [r / q / <Esc>] Reject"
  if opts.on_explain then
    controls = controls .. "    [e] Explain"
  end
  display[#display + 1] = controls

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, display)
  vim.bo[buf].modifiable = false

  -- Highlight badge and diff lines cleanly
  vim.api.nvim_buf_add_highlight(buf, M.ns, badge_hl, 0, 0, -1)
  for idx = diff_start_idx, diff_end_idx do
    local line = display[idx] or ""
    if line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
      vim.api.nvim_buf_add_highlight(buf, M.ns, "DiffAdd", idx - 1, 0, -1)
    elseif line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
      vim.api.nvim_buf_add_highlight(buf, M.ns, "DiffDelete", idx - 1, 0, -1)
    elseif line:sub(1, 2) == "@@" then
      vim.api.nvim_buf_add_highlight(buf, M.ns, "DiffChange", idx - 1, 0, -1)
    end
  end
  vim.api.nvim_buf_add_highlight(buf, M.ns, "AssistItActionKey", #display - 1, 0, -1)

  local width, height, row, col = compute_geometry(display)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = border,
    title = " " .. (opts.title or "AssistIt Proposed Edit") .. " ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false

  M.active_proposal = {
    win = win,
    buf = buf,
    target_buf = opts.target_buf,
    start_row0 = opts.start_row0,
    end_row0 = opts.end_row0,
    new_lines = vim.deepcopy(opts.new_lines),
    on_accept = opts.on_accept,
    on_reject = opts.on_reject,
    on_explain = opts.on_explain,
  }

  vim.keymap.set("n", "a", M.accept_active, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<CR>", M.accept_active, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "r", M.reject_active, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "q", M.reject_active, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", M.reject_active, { buffer = buf, silent = true, nowait = true })
  if opts.on_explain then
    vim.keymap.set("n", "e", function()
      local explain_cb = opts.on_explain
      M.close()
      explain_cb()
    end, { buffer = buf, silent = true, nowait = true })
  end

  return buf, win
end

return M
