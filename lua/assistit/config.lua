---@mod assistit.config Configuration, hardware profiles, and validation
local util = require("assistit.util")

local M = {}

M.PROVIDER_DEFAULTS = {
  ollama = {
    endpoint = "http://127.0.0.1:11434",
    model = "qwen2.5-coder:0.5b",
  },
  llamacpp = {
    endpoint = "http://127.0.0.1:8080",
    model = "qwen2.5-coder-0.5b-instruct-q4_k_m.gguf",
  },
  openai_compat = {
    endpoint = "http://127.0.0.1:1234",
    model = "qwen2.5-coder-1.5b-instruct",
  },
  none = {
    endpoint = "",
    model = "deterministic-only",
  },
}

---10 curated local coding models matching `setup.sh` and `setup.bat`.
M.RECOMMENDED_MODELS = {
  { id = 1, model = "qwen2.5-coder:0.5b", profile = "ultra_light", size = "~400 MB", ram = "~1 GB", desc = "Ultra-light CPU champion (4-8 GB laptops)" },
  { id = 2, model = "deepseek-coder:1.3b", profile = "ultra_light", size = "~780 MB", ram = "~2 GB", desc = "Fast multi-language FIM on CPU laptops" },
  { id = 3, model = "yi-coder:1.5b", profile = "balanced", size = "~870 MB", ram = "~2 GB", desc = "Compact 128K-context all-rounder" },
  { id = 4, model = "qwen2.5-coder:1.5b", profile = "balanced", size = "~990 MB", ram = "~2 GB", desc = "Everyday laptop sweet spot (8 GB+ RAM)" },
  { id = 5, model = "codegemma:2b", profile = "balanced", size = "~1.6 GB", ram = "~3 GB", desc = "Google fast FIM completion specialist" },
  { id = 6, model = "starcoder2:3b", profile = "balanced", size = "~1.7 GB", ram = "~4 GB", desc = "BigCode 600+ languages FIM model" },
  { id = 7, model = "qwen2.5-coder:3b", profile = "balanced", size = "~1.9 GB", ram = "~4 GB", desc = "Strong mid-size coder (8-16 GB RAM)" },
  { id = 8, model = "deepseek-coder:6.7b", profile = "performance", size = "~3.8 GB", ram = "~6 GB", desc = "Desktop / GPU high-accuracy coder" },
  { id = 9, model = "codellama:7b", profile = "performance", size = "~3.8 GB", ram = "~6 GB", desc = "Meta CodeLlama 7B FIM classic" },
  { id = 10, model = "qwen2.5-coder:7b", profile = "performance", size = "~4.7 GB", ram = "~8 GB", desc = "Workstation / GPU flagship coder" },
}

---Hardware profiles tuned for weak laptops up to workstations.
M.PROFILES = {
  ultra_light = {
    completion = {
      debounce_ms = 240,
      min_interval_ms = 350,
      cooldown_ms = 200,
      max_lines = 12,
      max_tokens = 96,
      stream = false,
      timeout_ms = 6000,
    },
    context = {
      max_prefix_chars = 1200,
      max_suffix_chars = 400,
      max_extra_chars = 350,
      include_diagnostics = true,
      include_treesitter_scope = true,
      include_project_symbols = false,
    },
    index = {
      enabled = false,
      max_files = 150,
      max_file_size_bytes = 65536,
    },
    quality = {
      intensity = "minimal",
      on_type = true,
      on_pause = false,
      on_save = true,
    },
  },

  balanced = {
    completion = {
      debounce_ms = 160,
      min_interval_ms = 220,
      cooldown_ms = 120,
      max_lines = 25,
      max_tokens = 192,
      stream = true,
      timeout_ms = 8000,
    },
    context = {
      max_prefix_chars = 2800,
      max_suffix_chars = 1000,
      max_extra_chars = 900,
      include_diagnostics = true,
      include_treesitter_scope = true,
      include_project_symbols = true,
    },
    index = {
      enabled = true,
      max_files = 500,
      max_file_size_bytes = 131072,
    },
    quality = {
      intensity = "standard",
      on_type = true,
      on_pause = true,
      on_save = true,
    },
  },

  performance = {
    completion = {
      debounce_ms = 100,
      min_interval_ms = 140,
      cooldown_ms = 60,
      max_lines = 48,
      max_tokens = 384,
      stream = true,
      timeout_ms = 12000,
    },
    context = {
      max_prefix_chars = 6000,
      max_suffix_chars = 2200,
      max_extra_chars = 2000,
      include_diagnostics = true,
      include_treesitter_scope = true,
      include_project_symbols = true,
    },
    index = {
      enabled = true,
      max_files = 2000,
      max_file_size_bytes = 262144,
    },
    quality = {
      intensity = "deep",
      on_type = true,
      on_pause = true,
      on_save = true,
    },
  },
}

---Base default configuration before profile and user overrides.
M.DEFAULTS = {
  enabled = true,
  short_commands = true,
  profile = "ultra_light",
  custom_profiles = {},

  provider = "ollama",
  model = nil, -- Resolved from provider defaults if omitted
  endpoint = nil, -- Resolved from provider defaults if omitted
  api_key_env = nil, -- Optional env var name for authenticated local proxies (never hardcoded)

  -- Optional Layer D larger local model for complex actions (Fix, Refactor, Review, Test)
  advanced = {
    enabled = false,
    provider = nil,
    model = nil,
    endpoint = nil,
    timeout_ms = 30000,
    max_tokens = 1024,
  },

  completion = {
    enabled = true,
    auto_trigger = true,
    debounce_ms = 240,
    min_interval_ms = 350,
    cooldown_ms = 200,
    min_line_chars = 1,
    max_lines = 12,
    max_tokens = 96,
    block_max_lines = 45,
    block_max_tokens = 320,
    temperature = 0.1,
    fim_template = "auto", -- "auto" | "qwen" | "deepseek" | "starcoder" | "codellama" | "codestral" | "prompt"
    stream = false,
    timeout_ms = 6000,
    progressive_accept = true,
    deterministic_fallback = true,
    respect_popup = true,
    warmup_on_startup = false,
    cache_size = 128,
    cache_ttl_ms = 300000, -- 5 minutes
    keymaps = {
      enabled = true,
      accept = "<Tab>",
      accept_word = "<M-w>",
      accept_word_alt = "<M-Tab>",
      accept_line = "<M-l>",
      dismiss = "<Esc>",
      esc_passthrough = false,
      next_suggestion = "<C-]>",
      complete_block = "<C-g><C-b>",
    },
  },

  deterministic = {
    enabled = true,
    autopairs = "auto", -- "auto" | true | false
    auto_cleanup_whitespace = false, -- Only runs when explicitly true (safe formatting rule)
    micro_completions = true,
    import_checks = true,
  },

  diagnostics = {
    enabled = true,
    ai_suggestions = true,
    automatic_fixes = false, -- Safety: never silently apply AI fixes; true only runs deterministic safe cleanup
    severity_min = vim.diagnostic.severity.WARN,
    virtual_indicator = true,
  },

  quality = {
    enabled = true,
    intensity = "minimal", -- "minimal" | "standard" | "deep"
    on_type = true,
    on_pause = false,
    on_save = true,
    pause_ms = 900,
  },

  context = {
    max_prefix_chars = 1200,
    max_suffix_chars = 400,
    max_extra_chars = 350,
    include_diagnostics = true,
    include_treesitter_scope = true,
    include_project_symbols = false,
    context_window_tokens = 2048,
  },

  index = {
    enabled = false,
    max_files = 150,
    max_file_size_bytes = 65536,
    respect_gitignore = true,
    ignore_patterns = {
      "node_modules",
      "%.git",
      "dist",
      "build",
      "target",
      "vendor",
      "__pycache__",
      "%.venv",
      "%.min%.js$",
      "%.lock$",
    },
  },

  personalization = {
    enabled = true,
    local_only = true,
    storage_path = nil, -- Defaults to stdpath("data")/assistit/personalization.json
    adapt_debounce = true,
    adapt_length = true,
  },

  privacy = {
    local_only = true,
    allow_remote = false,
    redact_secrets = true,
    blocked_file_patterns = {
      "^%.env$",
      "^%.env%.",
      "%.pem$",
      "%.key$",
      "%.p12$",
      "%.pfx$",
      "^id_rsa",
      "^id_ed25519",
      "^id_ecdsa",
      "credentials%.json$",
      "secrets?%.ya?ml$",
      "%.netrc$",
      "%.git%-credentials$",
    },
  },

  ui = {
    ghost_hl_group = "AssistItGhost",
    show_source_badge = false,
    show_latency_badge = false,
    border = "rounded",
    notify_level = vim.log.levels.WARN,
    progress_indicator = true,
  },

  ignore_buftypes = {
    prompt = true,
    terminal = true,
    nofile = true,
    help = true,
    quickfix = true,
  },

  ignore_filetypes = {
    TelescopePrompt = true,
    ["neo-tree"] = true,
    NvimTree = true,
    lazy = true,
    mason = true,
    gitcommit = false,
  },
}

---@type table
M.current = vim.deepcopy(M.DEFAULTS)
M.current.endpoint = M.PROVIDER_DEFAULTS.ollama.endpoint
M.current.model = M.PROVIDER_DEFAULTS.ollama.model

local VALID_PROVIDERS = {
  ollama = true,
  llamacpp = true,
  openai_compat = true,
  none = true,
}

local VALID_FIM_TEMPLATES = {
  auto = true,
  qwen = true,
  deepseek = true,
  starcoder = true,
  codellama = true,
  codestral = true,
  prompt = true,
}

local VALID_INTENSITIES = {
  minimal = true,
  standard = true,
  deep = true,
}

---Validate a resolved configuration table.
---Returns `(true, warnings)` or `(false, errors)`.
---@param cfg table
---@return boolean ok
---@return string[] messages
function M.validate(cfg)
  local errors = {}
  local warnings = {}

  if type(cfg) ~= "table" then
    return false, { "Configuration must be a table." }
  end

  if type(cfg.enabled) ~= "boolean" then
    errors[#errors + 1] = "`enabled` must be a boolean."
  end

  local custom = type(cfg.custom_profiles) == "table" and cfg.custom_profiles or {}
  if type(cfg.profile) ~= "string" or (not M.PROFILES[cfg.profile] and not custom[cfg.profile]) then
    errors[#errors + 1] = string.format(
      "Unknown `profile` %q. Expected 'ultra_light', 'balanced', 'performance', or a key in `custom_profiles`.",
      tostring(cfg.profile)
    )
  end

  if type(cfg.provider) ~= "string" or not VALID_PROVIDERS[cfg.provider] then
    errors[#errors + 1] = string.format(
      "Invalid `provider` %q. Supported providers: 'ollama', 'llamacpp', 'openai_compat', 'none'.",
      tostring(cfg.provider)
    )
  end

  if cfg.provider ~= "none" then
    if type(cfg.endpoint) ~= "string" or cfg.endpoint == "" then
      errors[#errors + 1] = "`endpoint` must be a non-empty URL string when provider is enabled."
    elseif cfg.privacy and cfg.privacy.local_only and not cfg.privacy.allow_remote then
      if not util.is_local_endpoint(cfg.endpoint) then
        errors[#errors + 1] = string.format(
          "Privacy guard blocked non-local `endpoint` %q while `privacy.local_only = true`. "
            .. "Use a local loopback address (127.0.0.1 / localhost) or explicitly opt in with `privacy = { local_only = false, allow_remote = true }`.",
          cfg.endpoint
        )
      end
    end

    if type(cfg.model) ~= "string" or cfg.model == "" then
      errors[#errors + 1] = "`model` must be a non-empty string."
    end
  end

  if cfg.advanced and cfg.advanced.enabled then
    local adv_prov = cfg.advanced.provider or cfg.provider
    if not VALID_PROVIDERS[adv_prov] then
      errors[#errors + 1] = string.format("Invalid `advanced.provider` %q.", tostring(adv_prov))
    end
    local adv_ep = cfg.advanced.endpoint or cfg.endpoint
    if adv_prov ~= "none" and cfg.privacy and cfg.privacy.local_only and not cfg.privacy.allow_remote then
      if not util.is_local_endpoint(adv_ep or "") then
        errors[#errors + 1] = string.format(
          "Privacy guard blocked non-local `advanced.endpoint` %q while `privacy.local_only = true`.",
          tostring(adv_ep)
        )
      end
    end
  end

  if type(cfg.completion) ~= "table" then
    errors[#errors + 1] = "`completion` must be a table."
  else
    if type(cfg.completion.debounce_ms) ~= "number" or cfg.completion.debounce_ms < 0 then
      errors[#errors + 1] = "`completion.debounce_ms` must be a number >= 0."
    end
    if type(cfg.completion.max_lines) ~= "number" or cfg.completion.max_lines < 1 then
      errors[#errors + 1] = "`completion.max_lines` must be a number >= 1."
    end
    if type(cfg.completion.max_tokens) ~= "number" or cfg.completion.max_tokens < 1 then
      errors[#errors + 1] = "`completion.max_tokens` must be a number >= 1."
    end
    if type(cfg.completion.timeout_ms) ~= "number" or cfg.completion.timeout_ms < 100 then
      errors[#errors + 1] = "`completion.timeout_ms` must be a number >= 100."
    end
    if not VALID_FIM_TEMPLATES[cfg.completion.fim_template] then
      errors[#errors + 1] = string.format(
        "Invalid `completion.fim_template` %q. Expected 'auto', 'qwen', 'deepseek', 'starcoder', 'codellama', 'codestral', or 'prompt'.",
        tostring(cfg.completion.fim_template)
      )
    end
  end

  if type(cfg.deterministic) == "table" then
    local ap = cfg.deterministic.autopairs
    if ap ~= "auto" and type(ap) ~= "boolean" then
      errors[#errors + 1] = "`deterministic.autopairs` must be 'auto', true, or false."
    end
  end

  if type(cfg.quality) == "table" then
    if not VALID_INTENSITIES[cfg.quality.intensity] then
      errors[#errors + 1] = string.format(
        "Invalid `quality.intensity` %q. Expected 'minimal', 'standard', or 'deep'.",
        tostring(cfg.quality.intensity)
      )
    end
  end

  if type(cfg.context) == "table" then
    if type(cfg.context.max_prefix_chars) ~= "number" or cfg.context.max_prefix_chars < 64 then
      errors[#errors + 1] = "`context.max_prefix_chars` must be a number >= 64."
    end
    if type(cfg.context.max_suffix_chars) ~= "number" or cfg.context.max_suffix_chars < 0 then
      errors[#errors + 1] = "`context.max_suffix_chars` must be a number >= 0."
    end
  end

  if cfg.personalization and cfg.personalization.enabled and cfg.personalization.local_only == false then
    warnings[#warnings + 1] =
      "assistit.nvim never uploads personalization data; `personalization.local_only` is enforced as true."
    cfg.personalization.local_only = true
  end

  if #errors > 0 then
    return false, errors
  end
  return true, warnings
end

---Resolve and apply user options on top of defaults and selected hardware profile.
---@param user_opts? table
---@return boolean ok
---@return table|string[] resolved_or_errors
---@return string[]? warnings
function M.setup(user_opts)
  user_opts = user_opts or {}
  if type(user_opts) ~= "table" then
    return false, { "`setup(opts)` expects a table or nil." }
  end

  local profile_name = user_opts.profile or M.DEFAULTS.profile
  local custom_profiles = type(user_opts.custom_profiles) == "table" and user_opts.custom_profiles or {}
  local profile_layer = custom_profiles[profile_name] or M.PROFILES[profile_name] or {}

  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.DEFAULTS), vim.deepcopy(profile_layer), user_opts)

  local pdef = M.PROVIDER_DEFAULTS[merged.provider] or M.PROVIDER_DEFAULTS.ollama
  if merged.endpoint == nil then
    merged.endpoint = pdef.endpoint
  end
  if merged.model == nil then
    merged.model = pdef.model
  end

  local ok, msgs = M.validate(merged)
  if not ok then
    return false, msgs
  end

  M.current = merged
  return true, M.current, msgs
end

local PROFILE_ALIASES = {
  u = "ultra_light",
  ultra = "ultra_light",
  light = "ultra_light",
  b = "balanced",
  bal = "balanced",
  p = "performance",
  perf = "performance",
}

---Switch active hardware profile at runtime while preserving explicit provider/model settings.
---@param profile_name string
---@return boolean ok
---@return string message
function M.set_profile(profile_name)
  local raw = util.trim(profile_name or "")
  local resolved = PROFILE_ALIASES[raw:lower()] or raw
  local custom = M.current.custom_profiles or {}
  local profile_layer = custom[resolved] or M.PROFILES[resolved]
  if not profile_layer then
    return false,
      string.format("Unknown profile %q. Available: ultra_light (u), balanced (b), performance (p).", tostring(raw))
  end
  M.current = vim.tbl_deep_extend("force", M.current, vim.deepcopy(profile_layer))
  M.current.profile = resolved
  return true, string.format("Switched profile to '%s'.", resolved)
end

---Switch active local model (by tag, 1-10 curated index, or 'none'/'offline').
---@param model_arg string
---@return boolean ok
---@return string message
function M.set_model(model_arg)
  local raw = util.trim(model_arg or "")
  if raw == "" then
    return false, "Specify a model tag, number (1-10), or 'none'."
  end
  local lower = raw:lower()
  if lower == "0" or lower == "none" or lower == "offline" then
    M.current.provider = "none"
    M.current.model = M.PROVIDER_DEFAULTS.none.model
    M.current.endpoint = ""
    return true, "Switched to offline deterministic mode (provider = 'none')."
  end

  local idx = tonumber(raw)
  local chosen_model = raw
  local suggested_profile = nil
  if idx and M.RECOMMENDED_MODELS[idx] then
    chosen_model = M.RECOMMENDED_MODELS[idx].model
    suggested_profile = M.RECOMMENDED_MODELS[idx].profile
  end

  if M.current.provider == "none" then
    M.current.provider = "ollama"
    if not M.current.endpoint or M.current.endpoint == "" then
      M.current.endpoint = M.PROVIDER_DEFAULTS.ollama.endpoint
    end
  end
  M.current.model = chosen_model
  if suggested_profile then
    M.set_profile(suggested_profile)
    return true, string.format("Switched model to '%s' (profile: %s).", chosen_model, suggested_profile)
  end
  return true, string.format("Switched model to '%s'.", chosen_model)
end

---Return current configuration table.
---@return table
function M.get()
  return M.current
end

return M
