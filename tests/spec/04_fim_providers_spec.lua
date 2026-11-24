local config = require("assistit.config")
local fim = require("assistit.providers.fim")
local providers = require("assistit.providers")

T.describe("FIM templates & local inference providers", function()
  T.it("detects model-specific FIM templates accurately", function()
    T.eq(fim.detect_template("qwen2.5-coder:0.5b", "auto"), "qwen")
    T.eq(fim.detect_template("deepseek-coder:1.3b", "auto"), "deepseek")
    T.eq(fim.detect_template("starcoder2:3b", "auto"), "starcoder")
    T.eq(fim.detect_template("codegemma:2b", "auto"), "starcoder")
    T.eq(fim.detect_template("codellama:7b-code", "auto"), "codellama")
    T.eq(fim.detect_template("codestral:22b", "auto"), "codestral")
    T.eq(fim.detect_template("llama3.2:1b", "auto"), "prompt")

    local built = fim.build_prompt({
      prefix = "local x = ",
      suffix = "\nreturn x",
      extra = "-- file: math.lua",
      language = "lua",
    }, "qwen2.5-coder:0.5b", "auto")

    T.truthy(built.supports_fim)
    T.matches(built.prompt, "<|fim_prefix|>")
    T.matches(built.prompt, "<|fim_suffix|>")
    T.matches(built.prompt, "<|fim_middle|>")
  end)

  T.it("sanitizes leaked FIM tokens, prefix echoes, and suffix overlaps", function()
    local cleaned = fim.clean_completion("local x = compute(y)<|endoftext|>garbage", {
      line_before = "local x = ",
      line_after = ")",
    }, 10)
    -- Prefix `local x = ` echoed -> stripped; trailing `)` overlaps `line_after = ")"` -> stripped!
    T.eq(cleaned, "compute(y")
  end)

  T.it("communicates with Ollama over async HTTP (JSON, NDJSON stream, health)", function()
    local ep = "http://127.0.0.1:" .. tostring(_G.ASSISTIT_TEST_PORT)
    local _, cfg = config.setup({
      provider = "ollama",
      endpoint = ep,
      model = "qwen2.5-coder:0.5b",
    })

    local health_ok, health_msg = nil, nil
    providers.check_health(cfg, function(ok, msg)
      health_ok, health_msg = ok, msg
    end)
    T.wait_until(3000, function()
      return health_ok ~= nil
    end)
    T.truthy(health_ok, health_msg)

    -- Streaming NDJSON completion
    local impl, opts = providers.resolve(cfg, { stream = true, max_lines = 10 })
    local partials = 0
    local done_res = nil
    impl.complete({ prefix = "local ", suffix = "", language = "lua" }, opts, {
      on_partial = function()
        partials = partials + 1
      end,
      on_done = function(err, res)
        T.eq(err, nil)
        done_res = res
      end,
    })
    T.wait_until(3000, function()
      return done_res ~= nil
    end)
    T.truthy(partials >= 1)
    T.eq(done_res.text, "result = a + b\nreturn result")
  end)

  T.it("communicates with llama.cpp (/infill, SSE stream, and /completion fallback)", function()
    local base_ep = "http://127.0.0.1:" .. tostring(_G.ASSISTIT_TEST_PORT)
    local _, cfg = config.setup({
      provider = "llamacpp",
      endpoint = base_ep,
      model = "qwen2.5-coder-0.5b.gguf",
    })

    local impl, opts = providers.resolve(cfg, { stream = true })
    local done_res = nil
    impl.complete({ prefix = "local ", suffix = "\nend", language = "lua" }, opts, {
      on_done = function(err, res)
        T.eq(err, nil)
        done_res = res
      end,
    })
    T.wait_until(3000, function()
      return done_res ~= nil
    end)
    T.eq(done_res.text, "result = a + b\nreturn result")

    -- Automatic fallback when `/infill` returns 404
    opts.endpoint = base_ep .. "/no-infill"
    opts.stream = false
    local fb_res = nil
    impl.complete({ prefix = "local ", suffix = "", language = "lua" }, opts, {
      on_done = function(err, res)
        T.eq(err, nil)
        fb_res = res
      end,
    })
    T.wait_until(3000, function()
      return fb_res ~= nil
    end)
    T.eq(fb_res.text, "result = a + b\nreturn result")
  end)

  T.it("communicates with OpenAI-compatible servers (/v1/completions & chat fallback)", function()
    local base_ep = "http://127.0.0.1:" .. tostring(_G.ASSISTIT_TEST_PORT)
    local _, cfg = config.setup({
      provider = "openai_compat",
      endpoint = base_ep .. "/chat-only",
      model = "qwen2.5-coder-1.5b",
    })
    local impl, opts = providers.resolve(cfg, { stream = false })
    local done_res = nil
    impl.complete({ prefix = "local ", suffix = "", language = "lua" }, opts, {
      on_done = function(err, res)
        T.eq(err, nil)
        done_res = res
      end,
    })
    T.wait_until(3000, function()
      return done_res ~= nil
    end)
    T.eq(done_res.text, "result = a + b\nreturn result")
  end)

  T.it("handles malformed JSON, empty responses, large responses, HTTP 500, and disconnects gracefully", function()
    local ep = "http://127.0.0.1:" .. tostring(_G.ASSISTIT_TEST_PORT)
    local _, cfg = config.setup({ provider = "ollama", endpoint = ep, model = "qwen2.5-coder:0.5b" })
    local impl, base_opts = providers.resolve(cfg, { stream = false, max_lines = 8 })

    local function run_scenario(scenario)
      local opts = vim.deepcopy(base_opts)
      opts.headers = { ["X-Mock-Scenario"] = scenario }
      local finished = false
      local out_err, out_res = nil, nil
      impl.complete({ prefix = "local ", suffix = "", language = "lua" }, opts, {
        on_done = function(e, r)
          out_err, out_res = e, r
          finished = true
        end,
      })
      T.wait_until(3000, function()
        return finished
      end)
      return out_err, out_res
    end

    local err_m = run_scenario("malformed")
    T.matches(err_m, "Malformed JSON")

    local err_500 = run_scenario("http500")
    T.matches(err_500, "HTTP 500")

    local err_disc = run_scenario("disconnect")
    T.truthy(err_disc ~= nil)

    local err_empty, res_empty = run_scenario("empty")
    T.eq(err_empty, nil)
    T.eq(res_empty.text, "")

    local err_large, res_large = run_scenario("large")
    T.eq(err_large, nil)
    local line_cnt = #vim.split(res_large.text, "\n", { plain = true })
    T.eq(line_cnt, 8)
  end)
end)
