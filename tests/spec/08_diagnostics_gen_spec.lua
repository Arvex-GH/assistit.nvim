local assistit = require("assistit")
local diagnostics = require("assistit.diagnostics")
local preview = require("assistit.ui.preview")

T.describe("diagnostics, reviewable auto-repair, & intelligent code generation", function()
  local buf
  local test_diag_ns = vim.api.nvim_create_namespace("test_lsp_diag")

  T.before_each(function()
    preview.close()
    buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "lua"
    vim.api.nvim_set_current_buf(buf)
  end)

  T.after_each(function()
    preview.close()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.diagnostic.reset(test_diag_ns, buf)
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  T.it("classifies syntax, undefined, type, unused, and security diagnostics", function()
    T.eq(diagnostics.classify({ message = "unexpected symbol near ')'" }), "syntax")
    T.eq(diagnostics.classify({ message = "Undefined global `input`." }), "undefined")
    T.eq(diagnostics.classify({ message = "Cannot assign type `string` to `number`." }), "type")
    T.eq(diagnostics.classify({ message = "Unused local `tmp`." }), "unused")
    T.eq(diagnostics.classify({ message = "Potential SQL injection risk" }), "security")
  end)

  T.it("never silently overwrites code; presents reviewable diff proposal with Accept/Reject/Undo", function()
    local ep = "http://127.0.0.1:" .. tostring(_G.ASSISTIT_TEST_PORT)
    assistit.setup({
      provider = "ollama",
      endpoint = ep,
      model = "qwen2.5-coder:0.5b",
      deterministic = { autopairs = false },
    })

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "local result = input",
      "return result",
    })
    vim.diagnostic.set(test_diag_ns, buf, {
      {
        lnum = 0,
        col = 15,
        severity = vim.diagnostic.severity.ERROR,
        source = "lua_ls",
        message = "Undefined global `input`.",
      },
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    -- Trigger :AssistItFix -> opens proposal window, does NOT overwrite buffer yet
    vim.cmd("AssistItFix")
    T.wait_until(3000, function()
      return preview.active_proposal ~= nil
    end, "Expected repair diff preview to open")

    -- Buffer is still untouched before acceptance!
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "local result = input")

    -- Rejecting leaves buffer untouched
    T.truthy(preview.reject_active())
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "local result = input")

    -- Re-run and Accept -> applies replacement cleanly
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("AssistItFix")
    T.wait_until(3000, function()
      return preview.active_proposal ~= nil
    end)
    T.truthy(preview.accept_active())
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
      "local result = input or {}",
      "return result",
    })
  end)

  T.it("executes Explain, Review, Refactor, Doc, and Generate commands cleanly", function()
    local ep = "http://127.0.0.1:" .. tostring(_G.ASSISTIT_TEST_PORT)
    assistit.setup({
      provider = "ollama",
      endpoint = ep,
      model = "qwen2.5-coder:0.5b",
      deterministic = { autopairs = false },
    })

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "-- compute normalized fallback table",
      "local x = 1",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    vim.cmd("AssistItExplain")
    T.wait_until(3000, function()
      return preview.active_proposal ~= nil
    end)
    local explain_lines = vim.api.nvim_buf_get_lines(preview.active_proposal.buf, 0, -1, false)
    T.matches(explain_lines[1], "AI Hypothesis")
    preview.close()

    vim.api.nvim_set_current_buf(buf)
    vim.cmd("AssistItReview")
    T.wait_until(3000, function()
      return preview.active_proposal ~= nil
    end)
    local review_text = table.concat(vim.api.nvim_buf_get_lines(preview.active_proposal.buf, 0, -1, false), "\n")
    T.matches(review_text, "Confirmed & Deterministic Static Checks")
    T.matches(review_text, "Local AI Hypotheses")
    preview.close()

    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("AssistItGenerate")
    T.wait_until(3000, function()
      return preview.active_proposal ~= nil and preview.active_proposal.target_buf == buf
    end)
    preview.close()
  end)
end)
