local assistit = require("assistit")
local cache = require("assistit.cache")
local completion = require("assistit.completion")
local ghost = require("assistit.completion.ghost")
local metrics = require("assistit.metrics")
local progressive = require("assistit.completion.progressive")
local transport = require("assistit.providers.transport")

T.describe("ghost-text completion, progressive accept, cancellation, & keymap safety", function()
  local buf

  T.before_each(function()
    transport.set_mock(nil)
    cache.global:clear()
    metrics.reset()
    buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "lua"
    vim.api.nvim_set_current_buf(buf)
  end)

  T.after_each(function()
    ghost.clear()
    completion.cancel_inflight()
    transport.set_mock(nil)
    package.loaded["cmp"] = nil
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  T.it("renders multi-line ghost text via extmarks and accepts full suggestion cleanly", function()
    local ep = "http://127.0.0.1:" .. tostring(_G.ASSISTIT_TEST_PORT)
    assistit.setup({
      provider = "ollama",
      endpoint = ep,
      model = "qwen2.5-coder:0.5b",
      deterministic = { autopairs = false },
    })

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local " })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })

    completion.trigger({ manual = true })
    T.wait_until(3000, function()
      return ghost.is_visible(buf)
    end, "Expected ghost text to become visible")

    local active = ghost.get()
    T.eq(active.text, "result = a + b\nreturn result")

    local marks = vim.api.nvim_buf_get_extmarks(buf, ghost.ns, 0, -1, { details = true })
    T.truthy(#marks >= 1)
    T.eq(marks[1][4].virt_text[1][1], "result = a + b")
    T.eq(#marks[1][4].virt_lines, 1)

    T.truthy(progressive.accept("full"))
    T.falsy(ghost.is_visible(buf))
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
      "local result = a + b",
      "return result",
    })
  end)

  T.it("supports progressive word-by-word and line-by-line acceptance without losing remainder", function()
    assistit.setup({ provider = "none", deterministic = { autopairs = false } })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "for " })
    vim.api.nvim_win_set_cursor(0, { 1, 4 })

    ghost.show(buf, 1, 4, "user in users do\n  notify(user)\nend", { source = "ai" })

    -- 1. Accept next word -> "user"
    T.truthy(progressive.accept("word"))
    T.eq(vim.api.nvim_get_current_line(), "for user")
    T.truthy(ghost.is_visible(buf))
    T.eq(ghost.get().text, " in users do\n  notify(user)\nend")

    -- 2. Accept next word -> " in"
    T.truthy(progressive.accept("word"))
    T.eq(vim.api.nvim_get_current_line(), "for user in")
    T.eq(ghost.get().text, " users do\n  notify(user)\nend")

    -- 3. Accept remainder of current line -> " users do"
    T.truthy(progressive.accept("line"))
    T.eq(vim.api.nvim_get_current_line(), "for user in users do")
    T.eq(ghost.get().text, "\n  notify(user)\nend")

    -- 4. Accept next line -> "\n  notify(user)"
    T.truthy(progressive.accept("line"))
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
      "for user in users do",
      "  notify(user)",
    })
    T.eq(ghost.get().text, "\nend")

    -- 5. Accept final line -> "\nend"
    T.truthy(progressive.accept("line"))
    T.falsy(ghost.is_visible(buf))
    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
      "for user in users do",
      "  notify(user)",
      "end",
    })
  end)

  T.it("never duplicates existing suffix characters on acceptance", function()
    assistit.setup({ provider = "none", deterministic = { autopairs = false } })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "process()" })
    -- Place cursor inside `process(|)` at col 8
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    ghost.show(buf, 1, 8, "items)", { source = "ai" })

    T.truthy(progressive.accept("full"))
    T.eq(vim.api.nvim_get_current_line(), "process(items)")
  end)

  T.it("rejects stale responses and cancels obsolete requests on rapid buffer edits", function()
    assistit.setup({
      provider = "ollama",
      endpoint = "http://127.0.0.1:11434",
      model = "qwen2.5-coder:0.5b",
      deterministic = { autopairs = false },
    })

    local pending_done = nil
    transport.set_mock(function(_, callbacks, handle)
      pending_done = function()
        if not handle:is_cancelled() then
          callbacks.on_done(nil, {
            status = 200,
            body = vim.json.encode({ response = "stale_text_should_be_rejected", done = true }),
            latency_ms = 200,
          })
        end
      end
      return handle
    end)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local a = " })
    vim.api.nvim_win_set_cursor(0, { 1, 10 })
    completion.trigger({ manual = true })
    T.truthy(pending_done ~= nil)

    -- Simulate user continuing to type before slow response arrives (mutates changedtick)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local a = 42" })
    vim.api.nvim_win_set_cursor(0, { 1, 12 })

    pending_done()
    T.falsy(ghost.is_visible(buf), "Stale response must never render on modified buffer")
    T.eq(metrics.state.stale_rejected, 1)
  end)

  T.it("preserves ordinary <Tab> when no suggestion is present or when cmp popup is visible", function()
    assistit.setup({
      provider = "none",
      deterministic = { autopairs = false },
    })
    vim.bo[buf].expandtab = true
    vim.bo[buf].shiftwidth = 2
    vim.bo[buf].tabstop = 2
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

    -- Enter insert mode and press <Tab> with NO ghost suggestion active
    local keys = vim.api.nvim_replace_termcodes("i<Tab><Esc>", true, false, true)
    vim.api.nvim_feedkeys(keys, "x", false)
    T.eq(vim.api.nvim_get_current_line(), "  ")

    -- Now show ghost text, but simulate nvim-cmp popup visible -> <Tab> must NOT accept ghost text!
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local " })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    ghost.show(buf, 1, 6, "should_not_accept", { source = "ai" })
    package.loaded["cmp"] = {
      visible = function()
        return true
      end,
    }

    local tab_only = vim.api.nvim_replace_termcodes("a<Tab><Esc>", true, false, true)
    vim.api.nvim_feedkeys(tab_only, "x", false)
    local line_after = vim.api.nvim_get_current_line()
    T.falsy(line_after:find("should_not_accept"), "Popup visibility must block ghost-text <Tab> hijack")
  end)
end)
