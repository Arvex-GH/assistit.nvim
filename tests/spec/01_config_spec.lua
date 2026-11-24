local config = require("assistit.config")

T.describe("config & hardware profiles", function()
  T.it("resolves sensible defaults for ultra_light profile", function()
    local ok, cfg = config.setup({})
    T.truthy(ok)
    T.eq(cfg.profile, "ultra_light")
    T.eq(cfg.provider, "ollama")
    T.eq(cfg.endpoint, "http://127.0.0.1:11434")
    T.eq(cfg.privacy.local_only, true)
    T.eq(cfg.diagnostics.automatic_fixes, false)
    T.eq(cfg.index.enabled, false)
  end)

  T.it("auto-selects provider-specific default endpoints when omitted", function()
    local ok1, cfg1 = config.setup({ provider = "llamacpp" })
    T.truthy(ok1)
    T.eq(cfg1.endpoint, "http://127.0.0.1:8080")

    local ok2, cfg2 = config.setup({ provider = "openai_compat" })
    T.truthy(ok2)
    T.eq(cfg2.endpoint, "http://127.0.0.1:1234")
  end)

  T.it("applies balanced and performance hardware profiles and user overrides", function()
    local ok, cfg = config.setup({
      profile = "balanced",
      completion = { max_lines = 19 },
    })
    T.truthy(ok)
    T.eq(cfg.profile, "balanced")
    T.eq(cfg.index.enabled, true)
    T.eq(cfg.completion.max_lines, 19)
    T.eq(cfg.completion.stream, true)

    local switched, _ = config.set_profile("performance")
    T.truthy(switched)
    T.eq(config.get().profile, "performance")
    T.eq(config.get().completion.max_tokens, 384)
  end)

  T.it("supports custom user-defined hardware profiles", function()
    local ok, cfg = config.setup({
      profile = "netbook_2012",
      custom_profiles = {
        netbook_2012 = {
          completion = { debounce_ms = 500, max_tokens = 48, max_lines = 5 },
          context = { max_prefix_chars = 512, max_suffix_chars = 128 },
        },
      },
    })
    T.truthy(ok)
    T.eq(cfg.completion.debounce_ms, 500)
    T.eq(cfg.context.max_prefix_chars, 512)
  end)

  T.it("rejects invalid provider, invalid profile, and remote endpoint under local_only", function()
    local ok_prov, errs_prov = config.setup({ provider = "cloud_magic" })
    T.falsy(ok_prov)
    T.matches(errs_prov[1], "Invalid `provider`")

    local ok_prof, errs_prof = config.setup({ profile = "nonexistent" })
    T.falsy(ok_prof)
    T.matches(errs_prof[1], "Unknown `profile`")

    local ok_remote, errs_remote = config.setup({
      provider = "openai_compat",
      endpoint = "https://api.openai.com/v1",
    })
    T.falsy(ok_remote)
    T.matches(errs_remote[1], "Privacy guard blocked non%-local")

    -- Explicit opt-in allows remote endpoint
    local ok_optin, _ = config.setup({
      provider = "openai_compat",
      endpoint = "https://api.example.com/v1",
      privacy = { local_only = false, allow_remote = true },
    })
    T.truthy(ok_optin)
  end)
end)
