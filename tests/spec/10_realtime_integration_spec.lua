local assistit = require("assistit")
local cache = require("assistit.cache")
local completion = require("assistit.completion")
local ghost = require("assistit.completion.ghost")
local metrics = require("assistit.metrics")
local providers = require("assistit.providers")
local transport = require("assistit.providers.transport")

T.describe("real-time editing flow, cancellation, offline fallback, & Layer D routing", function()
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
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  T.it("advances active ghost text in 0ms as user types matching characters and dismisses on <Esc>", function()
    assistit.setup({
      provider = "none",
      deterministic = { autopairs = false },
      completion = {
        keymaps = {
          enabled = true,
          dismiss = "<Esc>",
          esc_passthrough = false,
        },
      },
    })

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local " })

    _G._ASSISTIT_RT = {}
    local seq = table.concat({
      "A",
      "<Cmd>lua require('assistit.completion.ghost').show(0, 1, 6, 'result = 100', { source = 'ai' })<CR>",
      "res",
      "<Cmd>lua vim.api.nvim_exec_autocmds('TextChangedI', { buffer = 0 })<CR>",
      "<Cmd>lua _G._ASSISTIT_RT.vis1 = require('assistit.completion.ghost').is_visible(0); _G._ASSISTIT_RT.txt1 = require('assistit.completion.ghost').get() and require('assistit.completion.ghost').get().text<CR>",
      "<Esc>",
      "<Cmd>lua _G._ASSISTIT_RT.vis_after_esc1 = require('assistit.completion.ghost').is_visible(0); _G._ASSISTIT_RT.mode_after_esc1 = vim.api.nvim_get_mode().mode<CR>",
      "<Esc>",
    }, "")

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(seq, true, false, true), "mx", false)

    T.truthy(_G._ASSISTIT_RT.vis1)
    T.eq(_G._ASSISTIT_RT.txt1, "ult = 100")
    T.truthy(metrics.state.prefix_hits >= 1)
    -- First <Esc> dismissed suggestion while staying in Insert mode; second <Esc> exited Insert mode
    T.falsy(_G._ASSISTIT_RT.vis_after_esc1)
    T.eq(_G._ASSISTIT_RT.mode_after_esc1, "i")
    T.eq(vim.api.nvim_get_current_line(), "local res")
    _G._ASSISTIT_RT = nil
  end)

  T.it("cancels slow in-flight curl process immediately when user moves cursor or types", function()
    local ep = "http://127.0.0.1:" .. tostring(_G.ASSISTIT_TEST_PORT)
    assistit.setup({
      provider = "ollama",
      endpoint = ep,
      model = "qwen2.5-coder:0.5b",
      deterministic = { autopairs = false },
    })

    -- Inject slow scenario header via custom provider wrapper or request
    local orig_req = transport.request
    transport.set_mock(function(req, callbacks)
      req.headers = req.headers or {}
      req.headers["X-Mock-Scenario"] = "slow"
      transport.set_mock(nil)
      local h = orig_req(req, callbacks)
      return h
    end)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local slow_var = " })
    vim.api.nvim_win_set_cursor(0, { 1, 17 })
    completion.trigger({ manual = true })

    -- Immediately dismiss/cancel while slow HTTP request is still in-flight
    completion.cancel_inflight()
    T.eq(metrics.state.requests_cancelled, 1)
    T.falsy(ghost.is_visible(buf))
  end)

  T.it("falls back to Layer A deterministic completion gracefully when local model server is offline", function()
    -- Point to an unused closed loopback port
    assistit.setup({
      provider = "ollama",
      endpoint = "http://127.0.0.1:19",
      model = "qwen2.5-coder:0.5b",
      completion = {
        timeout_ms = 500,
        deterministic_fallback = true,
      },
      deterministic = {
        enabled = true,
        autopairs = false,
      },
    })

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "local configuration_profile = 'ultra_light'",
      "print(configurat",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 16 })

    completion.trigger({ manual = true })
    T.wait_until(2000, function()
      return ghost.is_visible(buf)
    end, "Expected deterministic fallback ghost text when server is unreachable")

    T.eq(ghost.get().source, "deterministic")
    T.eq(ghost.get().text, "ion_profile")
  end)

  T.it("routes inline completions to tiny Layer C model and deep actions to optional Layer D model", function()
    local ok, cfg = require("assistit.config").setup({
      provider = "ollama",
      endpoint = "http://127.0.0.1:11434",
      model = "qwen2.5-coder:0.5b",
      advanced = {
        enabled = true,
        provider = "llamacpp",
        endpoint = "http://127.0.0.1:8080",
        model = "qwen2.5-coder-7b-instruct.gguf",
      },
    })
    T.truthy(ok)

    local p_fast, opts_fast = providers.resolve(cfg, { use_advanced = false })
    T.eq(p_fast.name, "ollama")
    T.eq(opts_fast.model, "qwen2.5-coder:0.5b")

    local p_adv, opts_adv = providers.resolve(cfg, { use_advanced = true })
    T.eq(p_adv.name, "llamacpp")
    T.eq(opts_adv.model, "qwen2.5-coder-7b-instruct.gguf")
  end)
end)
