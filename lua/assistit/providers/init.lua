---@mod assistit.providers Provider registry and Layer C / Layer D model routing
local fim = require("assistit.providers.fim")
local llamacpp = require("assistit.providers.llamacpp")
local metrics = require("assistit.metrics")
local ollama = require("assistit.providers.ollama")
local openai_compat = require("assistit.providers.openai_compat")
local transport = require("assistit.providers.transport")

local M = {
  fim = fim,
  transport = transport,
  registry = {
    ollama = ollama,
    llamacpp = llamacpp,
    openai_compat = openai_compat,
  },
}

---Register a custom provider implementation.
---@param name string
---@param impl table
function M.register(name, impl)
  assert(type(name) == "string" and name ~= "", "Provider name must be a non-empty string")
  assert(type(impl) == "table" and type(impl.complete) == "function", "Provider must implement complete()")
  M.registry[name] = impl
end

---Resolve provider module and request options for Layer C (primary) or Layer D (`use_advanced = true`).
---@param cfg table
---@param opts? { use_advanced?: boolean, max_tokens?: integer, max_lines?: integer, temperature?: number, stream?: boolean, timeout_ms?: integer }
---@return table? provider_mod
---@return table resolved_opts
function M.resolve(cfg, opts)
  opts = opts or {}
  local use_adv = opts.use_advanced and cfg.advanced and cfg.advanced.enabled

  local prov_name = (use_adv and cfg.advanced.provider) or cfg.provider
  if prov_name == "none" then
    metrics.set_model_status("disabled", nil)
    return nil, { provider = "none" }
  end

  local impl = M.registry[prov_name]
  local endpoint = (use_adv and cfg.advanced.endpoint) or cfg.endpoint
  local model = (use_adv and cfg.advanced.model) or cfg.model

  local headers = {}
  if cfg.api_key_env and type(cfg.api_key_env) == "string" then
    local val = os.getenv(cfg.api_key_env)
    if val and val ~= "" then
      headers["Authorization"] = "Bearer " .. val
    end
  end

  local comp = cfg.completion or {}
  local resolved = {
    provider = prov_name,
    endpoint = endpoint,
    model = model,
    headers = headers,
    privacy = cfg.privacy,
    fim_template = comp.fim_template or "auto",
    max_tokens = opts.max_tokens
      or (use_adv and cfg.advanced.max_tokens)
      or comp.max_tokens
      or 96,
    max_lines = opts.max_lines or comp.max_lines or 12,
    temperature = opts.temperature or comp.temperature or 0.1,
    stream = opts.stream ~= nil and opts.stream or (comp.stream == true),
    timeout_ms = opts.timeout_ms
      or (use_adv and cfg.advanced.timeout_ms)
      or comp.timeout_ms
      or 8000,
    context_window_tokens = cfg.context and cfg.context.context_window_tokens or 2048,
  }

  return impl, resolved
end

---Check connection health of the configured primary provider and update metrics status.
---@param cfg table
---@param on_done? fun(ok: boolean, message: string)
function M.check_health(cfg, on_done)
  local impl, resolved = M.resolve(cfg)
  if not impl then
    if on_done then
      on_done(false, "Provider is set to 'none' (offline deterministic mode).")
    end
    return
  end
  impl.check_health(resolved, function(ok, msg)
    metrics.set_model_status(ok and "connected" or "disconnected", ok and nil or msg)
    if on_done then
      on_done(ok, msg)
    end
  end)
end

---Warm up the configured primary local model if supported.
---@param cfg table
---@param on_done? fun(ok: boolean, message: string)
function M.warmup(cfg, on_done)
  local impl, resolved = M.resolve(cfg)
  if not impl or not impl.warmup then
    if on_done then
      on_done(false, "Warm-up not available for provider")
    end
    return
  end
  impl.warmup(resolved, function(ok, msg)
    if ok then
      metrics.set_model_status("connected", nil)
    end
    if on_done then
      on_done(ok, msg)
    end
  end)
end

return M
