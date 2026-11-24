---@mod assistit.health Built-in `:checkhealth assistit` diagnostics
local config = require("assistit.config")
local metrics = require("assistit.metrics")
local personalization = require("assistit.personalization")
local privacy = require("assistit.privacy")
local providers = require("assistit.providers")

local M = {}

function M.check()
  local h = vim.health or require("health")
  local start = h.start or h.report_start
  local ok = h.ok or h.report_ok
  local warn = h.warn or h.report_warn
  local err = h.error or h.report_error
  local info = h.info or h.report_info

  start("assistit.nvim — Runtime & Compatibility")

  local v = vim.version()
  if v.major > 0 or (v.major == 0 and v.minor >= 10) then
    ok(string.format("Neovim %d.%d.%d meets minimum requirement (>= 0.10.0).", v.major, v.minor, v.patch))
  else
    err(string.format("Neovim %d.%d.%d is older than required 0.10.0.", v.major, v.minor, v.patch))
  end

  if vim.fn.executable("curl") == 1 then
    ok("`curl` found in PATH for non-blocking local HTTP inference.")
  else
    warn("`curl` not found in PATH. Deterministic Layer A works, but HTTP local model providers require `curl`.")
  end

  if vim.treesitter and vim.treesitter.get_parser then
    ok("Tree-sitter runtime API available.")
  else
    warn("Tree-sitter unavailable; scope extraction will use lightweight regex fallback.")
  end

  start("assistit.nvim — Privacy & Configuration")
  local cfg = config.get()
  local dest = privacy.describe_destination(cfg)
  info(string.format("Active hardware profile: %s (enabled = %s)", cfg.profile, tostring(cfg.enabled)))

  if dest.is_local then
    ok(string.format("Destination is strictly local: %s (%s)", dest.endpoint, dest.mode_label))
  else
    warn(string.format("Opt-in remote endpoint configured: %s", dest.endpoint))
  end

  if cfg.privacy and cfg.privacy.redact_secrets ~= false then
    ok("Secret redaction and sensitive file filtering (.env, keys, tokens) enabled.")
  else
    warn("`privacy.redact_secrets` is disabled; detected tokens will not be scrubbed from prompts.")
  end

  start("assistit.nvim — Local Model Provider")
  if cfg.provider == "none" then
    info("Provider set to 'none' (offline deterministic intelligence mode).")
  else
    local fim_tpl = providers.fim.detect_template(cfg.model, cfg.completion and cfg.completion.fim_template)
    info(string.format("Configured provider: %s | model: %s | FIM template: %s", cfg.provider, cfg.model, fim_tpl))

    -- Synchronous health probe bounded to 1.5s inside :checkhealth
    if vim.fn.executable("curl") == 1 then
      local done = false
      local probe_ok = false
      local probe_msg = "Timed out probing local server"
      providers.check_health(cfg, function(p_ok, p_msg)
        probe_ok = p_ok
        probe_msg = p_msg
        done = true
      end)
      vim.wait(1500, function()
        return done
      end, 25)
      if probe_ok then
        ok(probe_msg)
      else
        warn(probe_msg .. " (Layer A deterministic features remain active offline)")
      end
    end
  end

  start("assistit.nvim — Performance & Local Personalization")
  local snap = metrics.snapshot()
  info(
    string.format(
      "Latency stats: context avg %.2fms | HTTP avg %.1fms | cache hit ratio %.1f%%",
      snap.context_extract_ms.avg,
      snap.http_latency_ms.avg,
      snap.cache_hit_ratio * 100
    )
  )
  local p_info = personalization.inspect(cfg)
  ok("Personalization storage (local-only, no neural training): " .. p_info.storage_path)
end

return M
