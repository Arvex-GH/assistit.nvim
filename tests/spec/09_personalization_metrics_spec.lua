local assistit = require("assistit")
local health = require("assistit.health")
local metrics = require("assistit.metrics")
local personalization = require("assistit.personalization")

T.describe("local personalization, latency instrumentation, & healthcheck", function()
  T.it("adapts preferred length and debounce locally without storing raw source code", function()
    local tmp_json = vim.fn.tempname() .. "_personalization.json"
    assistit.setup({
      provider = "none",
      personalization = {
        enabled = true,
        storage_path = tmp_json,
      },
    })
    personalization.reset()

    for _ = 1, 8 do
      personalization.record_shown("lua")
      personalization.record_accepted("lua", "local x = 1\nreturn x", false)
    end

    -- High acceptance rate reduces debounce offset
    T.truthy(personalization.debounce_offset_ms("lua") < 0)
    -- Average accepted lines = 2 -> adapted cap is ceil(2 * 2.5) = 5 (< base 25)
    T.eq(personalization.recommended_max_lines("lua", 25), 5)

    T.truthy(personalization.save())
    local raw_disk = table.concat(vim.fn.readfile(tmp_json), "\n")
    T.falsy(raw_disk:find("local x = 1"), "Must never persist raw user code to disk")

    local info = personalization.inspect()
    T.eq(info.trains_neural_weights, false)
    T.eq(info.uploads_data, false)

    vim.cmd("AssistItResetLearning")
    T.eq(personalization.data.total_shown, 0)
    T.eq(vim.fn.filereadable(tmp_json), 0)
  end)

  T.it("scales adaptive debounce under slow CPU inference and enters backoff on repeated failures", function()
    metrics.reset()
    T.eq(metrics.adaptive_debounce_ms(200, 0), 200)

    metrics.record_request_start()
    metrics.record_request_success(1600, 1620)
    -- Latency > 1000ms scales debounce upward to prevent server queue flooding
    T.truthy(metrics.adaptive_debounce_ms(200, 0) >= 280)

    metrics.record_request_start()
    metrics.record_request_failure("connection refused")
    metrics.record_request_start()
    metrics.record_request_failure("connection refused")
    T.truthy(metrics.is_in_backoff())

    metrics.clear_backoff()
    T.falsy(metrics.is_in_backoff())
  end)

  T.it("runs :checkhealth assistit cleanly", function()
    local ep = "http://127.0.0.1:" .. tostring(_G.ASSISTIT_TEST_PORT)
    assistit.setup({
      provider = "ollama",
      endpoint = ep,
      model = "qwen2.5-coder:0.5b",
    })
    -- Should execute all health assertions without throwing
    health.check()
  end)
end)
