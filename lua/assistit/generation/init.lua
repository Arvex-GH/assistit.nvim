---@mod assistit.generation Intelligent code generation, refactoring, documentation, testing, and review
local buffer_intel = require("assistit.deterministic.buffer_intel")
local index = require("assistit.context.index")
local metrics = require("assistit.metrics")
local patch = require("assistit.generation.patch")
local preview = require("assistit.ui.preview")
local privacy = require("assistit.privacy")
local providers = require("assistit.providers")
local treesitter = require("assistit.lsp.treesitter")
local ui = require("assistit.ui")
local util = require("assistit.util")

local M = {
  patch = patch,
}

M._active_handle = nil

local function cancel_active_gen()
  if M._active_handle then
    local h = M._active_handle
    M._active_handle = nil
    if not h:is_cancelled() then
      h:cancel()
      metrics.record_cancelled()
    end
  end
end

---Sanitize snippet for safe outbound prompt construction.
---@param bufnr integer
---@param lines string[]
---@param cfg table
---@return boolean ok, string sanitized_or_reason
local function prepare_snippet(bufnr, lines, cfg)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local blocked, reason = privacy.is_sensitive_file(bufname, cfg.privacy and cfg.privacy.blocked_file_patterns)
  if blocked then
    return false, "Refusing to send sensitive file to model: " .. tostring(reason)
  end
  local text = table.concat(lines, "\n")
  if cfg.privacy and cfg.privacy.redact_secrets ~= false then
    text = privacy.redact_secrets(text)
  end
  return true, text
end

---Invoke local model for a structured task, routing to Layer D (`advanced`) when configured.
---@param spec { title: string, system: string, user: string, max_tokens?: integer }
---@param on_result fun(text: string, latency_ms: number)
local function run_model_task(spec, on_result)
  local cfg = require("assistit.config").get()
  if not cfg.enabled then
    ui.notify("assistit.nvim is currently disabled (:aion / :Aion).", vim.log.levels.WARN, true)
    return
  end

  metrics.clear_backoff()
  local provider_mod, req_opts = providers.resolve(cfg, {
    use_advanced = true,
    max_tokens = spec.max_tokens or 512,
    temperature = 0.2,
    stream = false,
    timeout_ms = (cfg.advanced and cfg.advanced.enabled and cfg.advanced.timeout_ms) or 25000,
  })

  if not provider_mod or not provider_mod.generate then
    ui.notify("No local AI model configured (`provider = 'none'`). Connect Ollama or llama.cpp for AI tasks.", vim.log.levels.WARN, true)
    return
  end

  cancel_active_gen()
  metrics.record_request_start()
  local t0 = util.now_ms()

  M._active_handle = provider_mod.generate({
    system = spec.system,
    user = spec.user,
  }, req_opts, {
    on_done = function(err, res)
      M._active_handle = nil
      if err then
        metrics.record_request_failure(err)
        ui.notify(spec.title .. " failed: " .. err, vim.log.levels.ERROR, true)
        return
      end
      local total_ms = util.now_ms() - t0
      metrics.record_request_success(res and res.latency_ms or total_ms, total_ms)
      on_result(res and res.text or "", res and res.latency_ms or total_ms)
    end,
  })
end

---Explain selected code or enclosing function concisely.
---@param opts? { line1?: integer, line2?: integer, range?: integer }
function M.explain(opts)
  local cfg = require("assistit.config").get()
  local bufnr = vim.api.nvim_get_current_buf()
  local s0, _, lines = patch.resolve_target_range(bufnr, opts)
  local ok, snippet = prepare_snippet(bufnr, lines, cfg)
  if not ok then
    ui.notify(snippet, vim.log.levels.WARN, true)
    return
  end

  local lang = treesitter.detect_language(bufnr, s0, 0, lines)
  run_model_task({
    title = "Explain",
    max_tokens = 384,
    system = "You are a concise senior engineer. Explain what the code does, key edge cases, and any subtle behavior in 3-8 bullet points.",
    user = string.format("Language: %s\n\n```%s\n%s\n```", lang, lang, snippet),
  }, function(text)
    preview.open_info({
      title = "AssistIt Explain",
      provenance = "ai_hypothesis",
      lines = text ~= "" and text or "Model returned an empty explanation.",
    })
  end)
end

---Propose a refactored version of selected code or enclosing function with diff preview.
---@param opts? { line1?: integer, line2?: integer, range?: integer, instruction?: string }
function M.refactor(opts)
  opts = opts or {}
  local cfg = require("assistit.config").get()
  local bufnr = vim.api.nvim_get_current_buf()
  local s0, e0, lines = patch.resolve_target_range(bufnr, opts)
  local ok, snippet = prepare_snippet(bufnr, lines, cfg)
  if not ok then
    ui.notify(snippet, vim.log.levels.WARN, true)
    return
  end

  local lang = treesitter.detect_language(bufnr, s0, 0, lines)
  local extra_goal = opts.instruction and opts.instruction ~= "" and ("Goal: " .. opts.instruction .. "\n") or ""

  run_model_task({
    title = "Refactor",
    max_tokens = 640,
    system = "Refactor the provided code for clarity, maintainability, and reduced duplication while preserving exact external behavior. Return a 1-sentence summary followed by ONE fenced code block containing the complete replacement.",
    user = string.format("%sLanguage: %s\n\n```%s\n%s\n```", extra_goal, lang, lang, snippet),
  }, function(text)
    local new_lines, summary = patch.extract_code_and_summary(text)
    if #new_lines == 0 then
      ui.notify("Model returned no refactored code.", vim.log.levels.WARN, true)
      return
    end
    preview.open_proposal({
      title = "AssistIt Refactor Proposal",
      provenance = "ai_hypothesis",
      summary = summary ~= "" and summary or "Proposed refactoring:",
      target_buf = bufnr,
      start_row0 = s0,
      end_row0 = e0,
      new_lines = new_lines,
      on_explain = function()
        M.explain({ range = 1, line1 = s0 + 1, line2 = e0 })
      end,
    })
  end)
end

---Propose performance/memory optimizations for selected code or enclosing function.
---@param opts? { line1?: integer, line2?: integer, range?: integer }
function M.optimize(opts)
  opts = vim.tbl_extend("force", opts or {}, {
    instruction = "Reduce unnecessary allocations, redundant work, and algorithmic overhead without sacrificing readability.",
  })
  M.refactor(opts)
end

---Generate idiomatic documentation/annotations for the enclosing function or selected symbol.
---@param opts? { line1?: integer, line2?: integer, range?: integer }
function M.doc(opts)
  local cfg = require("assistit.config").get()
  local bufnr = vim.api.nvim_get_current_buf()
  local s0, e0, lines = patch.resolve_target_range(bufnr, opts)
  local lang, ft = treesitter.detect_language(bufnr, s0, 0, lines)

  -- Deterministic fallback when offline (`provider == "none"`)
  if cfg.provider == "none" then
    local cmt = require("assistit.context").comment_leader(ft ~= "" and ft or lang)
    local stub = vim.list_extend({ cmt .. "TODO: Document behavior and parameters." }, lines)
    preview.open_proposal({
      title = "AssistIt Documentation Stub",
      provenance = "deterministic",
      summary = "Deterministic documentation template (no local AI model configured):",
      target_buf = bufnr,
      start_row0 = s0,
      end_row0 = e0,
      new_lines = stub,
    })
    return
  end

  local ok, snippet = prepare_snippet(bufnr, lines, cfg)
  if not ok then
    ui.notify(snippet, vim.log.levels.WARN, true)
    return
  end

  run_model_task({
    title = "Document",
    max_tokens = 640,
    system = "Add concise, idiomatic documentation comments and parameter/return type annotations to the given code without altering its logic. Return ONLY a single fenced code block containing the documented code.",
    user = string.format("Language: %s\n\n```%s\n%s\n```", lang, lang, snippet),
  }, function(text)
    local new_lines, summary = patch.extract_code_and_summary(text)
    if #new_lines == 0 then
      ui.notify("Model returned empty documentation output.", vim.log.levels.WARN, true)
      return
    end
    preview.open_proposal({
      title = "AssistIt Documentation Proposal",
      provenance = "ai_hypothesis",
      summary = summary ~= "" and summary or "Proposed documentation:",
      target_buf = bufnr,
      start_row0 = s0,
      end_row0 = e0,
      new_lines = new_lines,
    })
  end)
end

---Generate unit tests tailored to the function and detected project conventions.
---@param opts? { line1?: integer, line2?: integer, range?: integer }
function M.test(opts)
  local cfg = require("assistit.config").get()
  local bufnr = vim.api.nvim_get_current_buf()
  local s0, _, lines = patch.resolve_target_range(bufnr, opts)
  local ok, snippet = prepare_snippet(bufnr, lines, cfg)
  if not ok then
    ui.notify(snippet, vim.log.levels.WARN, true)
    return
  end

  local lang = treesitter.detect_language(bufnr, s0, 0, lines)
  local fw = index.state.conventions.test_framework or "standard unit test framework"
  local naming = index.state.conventions.naming or "snake_case"

  run_model_task({
    title = "Generate Tests",
    max_tokens = 768,
    system = "Generate focused, runnable unit tests covering normal behavior, edge cases, and error handling. Output a fenced code block.",
    user = string.format(
      "Language: %s\nTest framework convention: %s\nNaming convention: %s\n\n```%s\n%s\n```",
      lang,
      fw,
      naming,
      lang,
      snippet
    ),
  }, function(text)
    preview.open_info({
      title = "AssistIt Generated Tests (" .. fw .. ")",
      provenance = "ai_hypothesis",
      lines = text ~= "" and text or "Model returned no test output.",
    })
  end)
end

---Review buffer or selected range: runs Layer A deterministic static & security checks FIRST,
---then appends optional AI review hypotheses clearly separated by provenance.
---@param opts? { line1?: integer, line2?: integer, range?: integer }
function M.review(opts)
  local cfg = require("assistit.config").get()
  local bufnr = vim.api.nvim_get_current_buf()
  local full_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lang, ft = treesitter.detect_language(bufnr, 0, 0, full_lines)

  local det_findings = buffer_intel.analyze_lines(full_lines, {
    filetype = ft ~= "" and ft or lang,
    intensity = "deep",
  })

  local report = {
    "## 1. Confirmed & Deterministic Static Checks",
  }
  if #det_findings == 0 then
    report[#report + 1] = "- No deterministic import, unused-binding, conditional, or security pattern issues found."
  else
    for _, f in ipairs(det_findings) do
      report[#report + 1] = string.format("- Line %d [%s]: %s", f.lnum, f.category, f.message)
    end
  end

  if cfg.provider == "none" then
    preview.open_info({
      title = "AssistIt Code Review",
      provenance = "deterministic",
      lines = report,
    })
    return
  end

  local _, _, target_lines = patch.resolve_target_range(bufnr, opts)
  local ok, snippet = prepare_snippet(bufnr, target_lines, cfg)
  if not ok then
    preview.open_info({
      title = "AssistIt Code Review",
      provenance = "deterministic",
      lines = report,
    })
    return
  end

  run_model_task({
    title = "Code Review",
    max_tokens = 512,
    system = "Review the code for likely bugs, missing error handling, performance pitfalls, and security weaknesses. Be concise and avoid nitpicking formatting. Label uncertain guesses clearly.",
    user = string.format("Language: %s\n\n```%s\n%s\n```", lang, lang, snippet),
  }, function(ai_text)
    report[#report + 1] = ""
    report[#report + 1] = "## 2. Local AI Hypotheses (Unverified — Verify Manually)"
    for _, l in ipairs(util.split_lines(ai_text)) do
      report[#report + 1] = l
    end
    preview.open_info({
      title = "AssistIt Hybrid Code Review",
      provenance = "ai_hypothesis",
      lines = report,
    })
  end)
end

---Generate code at cursor from an explicit natural-language instruction or current-line comment.
---@param instruction? string
function M.generate(instruction)
  local cfg = require("assistit.config").get()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row0 = pos[1] - 1
  local cur_line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ""

  if not instruction or util.trim(instruction) == "" then
    -- Extract instruction from comment on current line if present
    instruction = cur_line:match("^%s*%-%-+%s*(.+)$")
      or cur_line:match("^%s*#+%s*(.+)$")
      or cur_line:match("^%s*//+%s*(.+)$")
  end

  if not instruction or util.trim(instruction) == "" then
    ui.notify("Provide an instruction (`:aig <prompt>` / `:Aig <prompt>`) or place cursor on a comment line.", vim.log.levels.WARN, true)
    return
  end

  local ctx = require("assistit.context").extract(bufnr, 0, cfg)
  if ctx.blocked then
    ui.notify("Refusing to generate inside sensitive file: " .. tostring(ctx.reason), vim.log.levels.WARN, true)
    return
  end

  local lang = ctx.language
  run_model_task({
    title = "Generate",
    max_tokens = 640,
    system = "Implement the requested code in the target language matching the surrounding context and indentation. Output ONLY a single fenced code block.",
    user = string.format(
      "Language: %s\nInstruction: %s\n\nSurrounding prefix:\n```%s\n%s\n```",
      lang,
      instruction,
      lang,
      ctx.prefix
    ),
  }, function(text)
    local new_lines = patch.extract_code_and_summary(text)
    if #new_lines == 0 then
      ui.notify("Model returned empty code generation.", vim.log.levels.WARN, true)
      return
    end
    -- Keep existing line if non-empty and insert generated lines right below, or replace comment if desired
    local preview_lines = vim.list_extend({ cur_line }, new_lines)
    preview.open_proposal({
      title = "AssistIt Generated Code",
      provenance = "ai_hypothesis",
      summary = "Instruction: " .. instruction,
      target_buf = bufnr,
      start_row0 = row0,
      end_row0 = row0 + 1,
      new_lines = preview_lines,
    })
  end)
end

return M
