---@mod assistit.ui.status Statusline component and detailed status dashboard
local cache = require("assistit.cache")
local index = require("assistit.context.index")
local metrics = require("assistit.metrics")
local personalization = require("assistit.personalization")
local preview = require("assistit.ui.preview")
local privacy = require("assistit.privacy")
local providers = require("assistit.providers")

local M = {}

---Compact statusline string suitable for native `statusline`, `lualine`, or `mini.statusline`.
---@return string
function M.statusline()
  local cfg = require("assistit.config").get()
  if not cfg.enabled then
    return "assistit:off"
  end
  if cfg.provider == "none" then
    return "assistit:det"
  end
  local snap = metrics.state
  local icon = "○"
  if snap.in_flight > 0 then
    icon = "⋯"
  elseif snap.model_status == "connected" then
    icon = "●"
  elseif snap.model_status == "disconnected" then
    icon = "×"
  end
  local lat = snap.http_latency_ms.samples > 0 and string.format(" %dms", math.floor(snap.http_latency_ms.avg)) or ""
  local short_model = (cfg.model or ""):gsub(":.*$", "")
  return string.format("assistit %s %s%s", icon, short_model, lat)
end

---Build structured status table for programmatic inspection and `:AssistItStatus`.
---@return table
function M.collect()
  local cfg = require("assistit.config").get()
  local snap = metrics.snapshot()
  local dest = privacy.describe_destination(cfg)
  local fim_key = providers.fim.detect_template(cfg.model, cfg.completion and cfg.completion.fim_template)
  return {
    enabled = cfg.enabled,
    profile = cfg.profile,
    destination = dest,
    model = cfg.model,
    fim_template = fim_key,
    advanced = {
      enabled = cfg.advanced and cfg.advanced.enabled or false,
      model = cfg.advanced and cfg.advanced.model or nil,
    },
    metrics = snap,
    cache_entries = cache.global:count(),
    index = index.summary(),
    personalization = personalization.inspect(cfg),
  }
end

---Format status report lines for floating dashboard.
---@param info table
---@return string[]
function M.format_lines(info)
  local m = info.metrics
  local lines = {
    string.format("State:           %s  (profile: %s)", info.enabled and "ENABLED" or "DISABLED", info.profile),
    string.format("Privacy Mode:    %s", info.destination.mode_label),
    string.format("Provider:        %s  ->  %s", info.destination.provider, info.destination.endpoint),
    string.format("Primary Model:   %s  (FIM template: %s)", tostring(info.model), info.fim_template),
    string.format("Connection:      %s%s", m.model_status:upper(), m.last_error and (" (" .. m.last_error .. ")") or ""),
  }

  if info.advanced.enabled then
    lines[#lines + 1] = string.format("Advanced Model:  %s (Layer D active)", tostring(info.advanced.model or "default"))
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Performance & Latency (measured locally):"
  lines[#lines + 1] = string.format(
    "  Context extract:  avg %.2fms  (last %.2fms, max %.2fms)",
    m.context_extract_ms.avg,
    m.context_extract_ms.last,
    m.context_extract_ms.max
  )
  lines[#lines + 1] = string.format(
    "  HTTP inference:   avg %.1fms  (last %.1fms, samples %d)",
    m.http_latency_ms.avg,
    m.http_latency_ms.last,
    m.http_latency_ms.samples
  )
  if m.ttft_ms.samples > 0 then
    lines[#lines + 1] = string.format("  First token:      avg %.1fms  (last %.1fms)", m.ttft_ms.avg, m.ttft_ms.last)
  end
  lines[#lines + 1] = string.format("  Plugin overhead:  avg %.2fms", m.plugin_overhead_ms.avg)
  lines[#lines + 1] = string.format(
    "  Cache hit ratio:  %.1f%%  (%d hits, %d prefix-continuations, %d cached)",
    m.cache_hit_ratio * 100,
    m.cache_hits,
    m.prefix_hits,
    info.cache_entries
  )
  lines[#lines + 1] = string.format(
    "  Requests:         %d ok / %d cancelled / %d stale-rejected / %d deterministic",
    m.requests_succeeded,
    m.requests_cancelled,
    m.stale_rejected,
    m.deterministic_hits
  )

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Context Index & Personalization:"
  lines[#lines + 1] = string.format(
    "  Project index:    %s (%d files, %d symbols)",
    info.index.indexed and "ready" or "inactive",
    info.index.file_count,
    info.index.symbol_count
  )
  lines[#lines + 1] = string.format(
    "  Personalization:  %d accepted / %d shown (%.0f%%), avg %.1f lines",
    info.personalization.total_accepted_full + info.personalization.total_accepted_partial,
    info.personalization.total_shown,
    info.personalization.acceptance_rate * 100,
    info.personalization.avg_accepted_lines
  )
  lines[#lines + 1] = "  Stored locally:   " .. info.personalization.storage_path

  return lines
end

---Open `:AssistItStatus` floating window and probe live backend health asynchronously.
function M.open()
  local cfg = require("assistit.config").get()
  local info = M.collect()
  local buf, win = preview.open_info({
    title = "AssistIt Status",
    provenance = "deterministic",
    lines = M.format_lines(info),
  })

  if cfg.provider ~= "none" then
    providers.check_health(cfg, function()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win) then
        local refreshed = M.collect()
        local badge, _ = preview.provenance_badge("deterministic")
        local new_content = {
          badge,
          string.rep("─", math.min(60, math.max(24, #badge))),
        }
        for _, l in ipairs(M.format_lines(refreshed)) do
          new_content[#new_content + 1] = l
        end
        new_content[#new_content + 1] = ""
        new_content[#new_content + 1] = "[q / <Esc>] Close"
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_content)
        vim.bo[buf].modifiable = false
      end
    end)
  end
end

return M
