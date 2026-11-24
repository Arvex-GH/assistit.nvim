---@mod assistit.diagnostics Intelligent error detection, LSP code-action priority, and reviewable AI repair
local lsp = require("assistit.lsp")
local metrics = require("assistit.metrics")
local patch = require("assistit.generation.patch")
local preview = require("assistit.ui.preview")
local privacy = require("assistit.privacy")
local providers = require("assistit.providers")
local quality = require("assistit.diagnostics.quality")
local ui = require("assistit.ui")
local util = require("assistit.util")

local M = {
  quality = quality,
}

---Classify a diagnostic entry into a semantic issue category.
---@param diag { message?: string, code?: string|number, severity?: integer, source?: string }
---@return "syntax"|"undefined"|"type"|"unused"|"security"|"lint"
function M.classify(diag)
  local msg = ((diag and diag.message) or ""):lower()
  local code = tostring((diag and diag.code) or ""):lower()

  if
    msg:find("syntax", 1, true)
    or msg:find("unexpected", 1, true)
    or msg:find("expected", 1, true)
    or msg:find("unterminated", 1, true)
    or msg:find("parse", 1, true)
  then
    return "syntax"
  elseif
    msg:find("undefined", 1, true)
    or msg:find("undeclared", 1, true)
    or msg:find("not defined", 1, true)
    or msg:find("cannot find", 1, true)
    or msg:find("unresolved", 1, true)
  then
    return "undefined"
  elseif
    msg:find("type", 1, true)
    or msg:find("mismatch", 1, true)
    or msg:find("assignable", 1, true)
  then
    return "type"
  elseif
    msg:find("unused", 1, true)
    or msg:find("never read", 1, true)
    or code:find("unused", 1, true)
  then
    return "unused"
  elseif
    msg:find("security", 1, true)
    or msg:find("injection", 1, true)
    or msg:find("secret", 1, true)
    or code:find("security", 1, true)
  then
    return "security"
  end

  return "lint"
end

---Locate the highest-priority diagnostic on `row0` (or nearest line in `bufnr`).
---@param bufnr integer
---@param row0 integer 0-indexed cursor line
---@return table? diag
function M.find_target_diagnostic(bufnr, row0)
  local on_line = lsp.get_diagnostics(bufnr, row0)
  if #on_line > 0 then
    table.sort(on_line, function(a, b)
      return (a.severity or 4) < (b.severity or 4)
    end)
    return on_line[1]
  end

  local all = lsp.get_diagnostics(bufnr)
  if #all == 0 then
    -- Run fresh deterministic scan if buffer has no diagnostics yet
    quality.run_buffer(bufnr, "standard")
    all = lsp.get_diagnostics(bufnr)
  end
  if #all == 0 then
    return nil
  end

  table.sort(all, function(a, b)
    local sa, sb = (a.severity or 4), (b.severity or 4)
    if sa ~= sb then
      return sa < sb
    end
    return math.abs((a.lnum or 0) - row0) < math.abs((b.lnum or 0) - row0)
  end)
  return all[1]
end

---Explain a specific diagnostic using deterministic classification + optional AI reasoning.
---@param bufnr integer
---@param diag table
function M.explain_diagnostic(bufnr, diag)
  local cfg = require("assistit.config").get()
  local category = M.classify(diag)
  local is_det = diag.namespace == quality.ns
  local prov = is_det and "deterministic" or "confirmed"
  local lnum1 = (diag.lnum or 0) + 1
  local src = diag.source or "diagnostic"

  if cfg.provider == "none" or (cfg.diagnostics and cfg.diagnostics.ai_suggestions == false) then
    preview.open_info({
      title = "AssistIt Diagnostic Explanation",
      provenance = prov,
      lines = {
        string.format("Line %d [%s / %s]:", lnum1, src, category),
        diag.message or "",
        "",
        "Connect a local AI model (`ollama` or `llamacpp`) for deeper root-cause hypotheses.",
      },
    })
    return
  end

  local total = vim.api.nvim_buf_line_count(bufnr)
  local s0 = util.clamp((diag.lnum or 0) - 6, 0, math.max(0, total - 1))
  local e0 = util.clamp((diag.lnum or 0) + 7, s0 + 1, total)
  local snippet = table.concat(vim.api.nvim_buf_get_lines(bufnr, s0, e0, false), "\n")
  if cfg.privacy and cfg.privacy.redact_secrets ~= false then
    snippet = privacy.redact_secrets(snippet)
  end

  local provider_mod, req_opts = providers.resolve(cfg, {
    use_advanced = true,
    max_tokens = 384,
    temperature = 0.15,
  })
  if not provider_mod then
    return
  end

  metrics.record_request_start()
  local t0 = util.now_ms()
  provider_mod.generate({
    system = "Explain the reported diagnostic concisely: (1) confirmed meaning of the error, (2) likely cause in this snippet, and (3) how to fix it safely.",
    user = string.format(
      "Diagnostic [%s / %s] on line %d: %s\n\nCode context:\n```\n%s\n```",
      src,
      category,
      lnum1,
      diag.message or "",
      snippet
    ),
  }, req_opts, {
    on_done = function(err, res)
      if err then
        metrics.record_request_failure(err)
        ui.notify("Explain failed: " .. err, vim.log.levels.ERROR, true)
        return
      end
      local dt = util.now_ms() - t0
      metrics.record_request_success(res and res.latency_ms or dt, dt)
      preview.open_info({
        title = "AssistIt Diagnostic Explanation",
        provenance = "ai_hypothesis",
        lines = {
          string.format("Confirmed Issue [%s / %s, line %d]: %s", src, category, lnum1, diag.message or ""),
          "",
          "AI Root-Cause Hypothesis (Unverified):",
          res and res.text or "",
        },
      })
    end,
  })
end

---Inspect and propose a safe, reviewable repair for the diagnostic or selected range.
---Priority order: (1) Deterministic fix -> (2) LSP Code Action -> (3) Local AI repair diff.
---@param opts? { line1?: integer, line2?: integer, range?: integer }
function M.fix(opts)
  opts = opts or {}
  local cfg = require("assistit.config").get()
  if not cfg.enabled then
    ui.notify("assistit.nvim is disabled (:AssistItEnable).", vim.log.levels.WARN, true)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local blocked, reason = privacy.is_sensitive_file(bufname, cfg.privacy and cfg.privacy.blocked_file_patterns)
  if blocked then
    ui.notify("Refusing to run AI repair on sensitive file: " .. tostring(reason), vim.log.levels.WARN, true)
    return
  end

  local pos = vim.api.nvim_win_get_cursor(0)
  local row0 = pos[1] - 1
  local col0 = pos[2]

  local diag = (not opts.range or opts.range == 0) and M.find_target_diagnostic(bufnr, row0) or nil

  -- 1. Deterministic repair when diagnostic carries an exact deterministic replacement
  if diag and diag.user_data and diag.user_data.assistit_finding then
    local finding = diag.user_data.assistit_finding
    if finding.replacement ~= nil then
      local new_lines = finding.replacement == "" and {} or { finding.replacement }
      preview.open_proposal({
        title = "AssistIt Deterministic Fix",
        provenance = "deterministic",
        summary = string.format("⚠ Issue (line %d): %s", finding.lnum, finding.message),
        target_buf = bufnr,
        start_row0 = finding.lnum - 1,
        end_row0 = finding.lnum,
        new_lines = new_lines,
        on_accept = function()
          quality.run_buffer(bufnr)
        end,
        on_explain = function()
          M.explain_diagnostic(bufnr, diag)
        end,
      })
      return
    end
  end

  -- 2. Check attached LSP servers for native quickfix code actions first
  local diag_row0 = diag and diag.lnum or row0
  lsp.query_code_actions(bufnr, diag_row0, col0, function(actions)
    if #actions > 0 then
      local first = actions[1]
      -- Present LSP action confirmation in preview window or trigger vim.ui.select if multiple
      if first.action and (first.action.edit or first.action.command) then
        vim.ui.select(actions, {
          prompt = "AssistIt — Confirmed LSP Code Actions Available:",
          format_item = function(item)
            return "[LSP] " .. item.title
          end,
        }, function(choice)
          if choice then
            lsp.apply_code_action(choice, bufnr)
          end
        end)
        return
      end
    end

    -- 3. Local AI context-aware repair proposal (always reviewable & reversible!)
    if cfg.provider == "none" or (cfg.diagnostics and cfg.diagnostics.ai_suggestions == false) then
      if diag then
        M.explain_diagnostic(bufnr, diag)
      else
        ui.notify("No diagnostics found and no local AI model configured.", vim.log.levels.INFO, true)
      end
      return
    end

    local total = vim.api.nvim_buf_line_count(bufnr)
    local s0, e0, target_lines
    if opts.range and opts.range > 0 then
      s0, e0, target_lines = patch.resolve_target_range(bufnr, opts)
    elseif diag then
      s0 = util.clamp(diag_row0 - 3, 0, math.max(0, total - 1))
      e0 = util.clamp((diag.end_lnum or diag_row0) + 4, s0 + 1, total)
      target_lines = vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
    else
      s0, e0, target_lines = patch.resolve_target_range(bufnr, opts)
    end

    local snippet = table.concat(target_lines, "\n")
    if cfg.privacy and cfg.privacy.redact_secrets ~= false then
      snippet = privacy.redact_secrets(snippet)
    end

    local lang = util.filetype_language(vim.bo[bufnr].filetype)
    local diag_header = diag
        and string.format(
          "Confirmed diagnostic [%s / %s] at line %d (relative line %d in snippet): %s",
          diag.source or "diagnostic",
          M.classify(diag),
          diag_row0 + 1,
          (diag_row0 - s0) + 1,
          diag.message or ""
        )
      or "Inspect this code block for likely bugs or errors and fix them."

    metrics.clear_backoff()
    local provider_mod, req_opts = providers.resolve(cfg, {
      use_advanced = true,
      max_tokens = 512,
      temperature = 0.15,
    })
    if not provider_mod then
      return
    end

    metrics.record_request_start()
    local t0 = util.now_ms()
    provider_mod.generate({
      system = "Fix the issue in the provided code snippet with minimal, safe changes. Preserve indentation and surrounding behavior. Output a 1-line explanation followed by ONE fenced code block containing ONLY the replacement lines for the snippet.",
      user = string.format("%s\nLanguage: %s\n\n```%s\n%s\n```", diag_header, lang, lang, snippet),
    }, req_opts, {
      on_done = function(err, res)
        if err then
          metrics.record_request_failure(err)
          ui.notify("AI repair request failed: " .. err, vim.log.levels.ERROR, true)
          return
        end
        local dt = util.now_ms() - t0
        metrics.record_request_success(res and res.latency_ms or dt, dt)

        local new_lines, summary = patch.extract_code_and_summary(res and res.text or "")
        if #new_lines == 0 then
          ui.notify("Model did not return a valid code replacement.", vim.log.levels.WARN, true)
          return
        end

        local issue_banner = diag
            and string.format("⚠ Confirmed Issue [%s]: %s\nAI Repair Hypothesis: %s", M.classify(diag), diag.message or "", summary)
          or ("✦ Potential Fix Hypothesis: " .. (summary ~= "" and summary or "Review diff carefully"))

        preview.open_proposal({
          title = "AssistIt Proposed Repair",
          provenance = "ai_hypothesis",
          summary = issue_banner,
          target_buf = bufnr,
          start_row0 = s0,
          end_row0 = e0,
          new_lines = new_lines,
          on_explain = diag and function()
            M.explain_diagnostic(bufnr, diag)
          end or nil,
        })
      end,
    })
  end)
end

function M.setup(cfg)
  quality.setup(cfg)
end

function M.teardown()
  quality.teardown()
end

return M
