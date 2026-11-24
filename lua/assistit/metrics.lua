---@mod assistit.metrics Local performance instrumentation and adaptive scheduler
---Strictly in-memory local runtime metrics. Never transmitted anywhere.
local util = require("assistit.util")

local M = {}

local function initial_state()
  return {
    context_extract_ms = { last = 0, avg = 0, max = 0, samples = 0 },
    http_latency_ms = { last = 0, avg = 0, max = 0, samples = 0 },
    ttft_ms = { last = 0, avg = 0, max = 0, samples = 0 },
    total_completion_ms = { last = 0, avg = 0, max = 0, samples = 0 },
    plugin_overhead_ms = { last = 0, avg = 0, max = 0, samples = 0 },

    requests_sent = 0,
    requests_succeeded = 0,
    requests_failed = 0,
    requests_cancelled = 0,
    stale_rejected = 0,
    in_flight = 0,

    cache_hits = 0,
    prefix_hits = 0,
    cache_misses = 0,

    deterministic_hits = 0,

    model_status = "unknown", -- "unknown" | "connected" | "disconnected" | "disabled"
    last_error = nil,
    last_request_at_ms = 0,
    last_completed_at_ms = 0,
    consecutive_failures = 0,
    backoff_until_ms = 0,
  }
end

M.state = initial_state()

---@param bucket { last: number, avg: number, max: number, samples: integer }
---@param val number
local function record_sample(bucket, val)
  if type(val) ~= "number" or val < 0 then
    return
  end
  bucket.last = val
  bucket.samples = bucket.samples + 1
  if bucket.samples == 1 then
    bucket.avg = val
  else
    -- Exponential moving average (alpha = 0.25) for responsive adaptation
    bucket.avg = bucket.avg * 0.75 + val * 0.25
  end
  if val > bucket.max then
    bucket.max = val
  end
end

function M.record_context_time(ms)
  record_sample(M.state.context_extract_ms, ms)
end

function M.record_plugin_overhead(ms)
  record_sample(M.state.plugin_overhead_ms, ms)
end

function M.record_ttft(ms)
  record_sample(M.state.ttft_ms, ms)
end

function M.record_request_start()
  M.state.requests_sent = M.state.requests_sent + 1
  M.state.in_flight = M.state.in_flight + 1
  M.state.last_request_at_ms = util.now_ms()
end

---@param http_ms number
---@param total_ms number
function M.record_request_success(http_ms, total_ms)
  M.state.in_flight = math.max(0, M.state.in_flight - 1)
  M.state.requests_succeeded = M.state.requests_succeeded + 1
  M.state.consecutive_failures = 0
  M.state.backoff_until_ms = 0
  M.state.model_status = "connected"
  M.state.last_error = nil
  M.state.last_completed_at_ms = util.now_ms()
  record_sample(M.state.http_latency_ms, http_ms)
  record_sample(M.state.total_completion_ms, total_ms)
  record_sample(M.state.plugin_overhead_ms, math.max(0, total_ms - http_ms))
end

---@param err string?
function M.record_request_failure(err)
  M.state.in_flight = math.max(0, M.state.in_flight - 1)
  M.state.requests_failed = M.state.requests_failed + 1
  M.state.consecutive_failures = M.state.consecutive_failures + 1
  M.state.model_status = "disconnected"
  M.state.last_error = err or "request failed"

  -- Polite exponential backoff for background auto-triggers when local server is offline
  if M.state.consecutive_failures >= 2 then
    local factor = math.min(5, M.state.consecutive_failures - 1)
    local delay_ms = math.min(30000, 2000 * (2 ^ factor))
    M.state.backoff_until_ms = util.now_ms() + delay_ms
  end
end

function M.record_cancelled()
  M.state.in_flight = math.max(0, M.state.in_flight - 1)
  M.state.requests_cancelled = M.state.requests_cancelled + 1
end

function M.record_stale_rejected()
  M.state.stale_rejected = M.state.stale_rejected + 1
end

---@param is_prefix? boolean
function M.record_cache_hit(is_prefix)
  M.state.cache_hits = M.state.cache_hits + 1
  if is_prefix then
    M.state.prefix_hits = M.state.prefix_hits + 1
  end
end

function M.record_cache_miss()
  M.state.cache_misses = M.state.cache_misses + 1
end

function M.record_deterministic_hit()
  M.state.deterministic_hits = M.state.deterministic_hits + 1
end

---@param status "unknown"|"connected"|"disconnected"|"disabled"
---@param err? string
function M.set_model_status(status, err)
  M.state.model_status = status
  M.state.last_error = err
  if status == "connected" then
    M.state.consecutive_failures = 0
    M.state.backoff_until_ms = 0
  end
end

---Reset backoff so an explicit manual command immediately attempts connection.
function M.clear_backoff()
  M.state.backoff_until_ms = 0
  M.state.consecutive_failures = 0
end

---Check whether background auto-trigger requests are currently in backoff due to offline backend.
---@return boolean
function M.is_in_backoff()
  if M.state.backoff_until_ms <= 0 then
    return false
  end
  return util.now_ms() < M.state.backoff_until_ms
end

---Compute cache hit ratio in [0.0, 1.0].
---@return number
function M.cache_hit_ratio()
  local total = M.state.cache_hits + M.state.cache_misses
  if total == 0 then
    return 0
  end
  return M.state.cache_hits / total
end

---Adaptive debounce calculation: scales wait interval smoothly when CPU inference is slow,
---preventing request pile-up on weak laptops without penalizing fast setups.
---@param base_ms number
---@param personal_offset_ms? number
---@return integer
function M.adaptive_debounce_ms(base_ms, personal_offset_ms)
  local adjusted = base_ms + (personal_offset_ms or 0)
  local avg_http = M.state.http_latency_ms.avg
  if M.state.http_latency_ms.samples > 0 then
    if avg_http > 2000 then
      adjusted = adjusted * 1.9
    elseif avg_http > 1000 then
      adjusted = adjusted * 1.45
    elseif avg_http > 500 then
      adjusted = adjusted * 1.15
    end
  end
  return math.floor(util.clamp(adjusted, 40, 1500))
end

---Check minimum typing/cooldown intervals before issuing a new background request.
---@param min_interval_ms number
---@param cooldown_ms number
---@return boolean allowed
---@return integer wait_remaining_ms
function M.can_schedule_request(min_interval_ms, cooldown_ms)
  local now = util.now_ms()
  if M.state.last_request_at_ms > 0 then
    local since_req = now - M.state.last_request_at_ms
    if since_req < min_interval_ms then
      return false, math.ceil(min_interval_ms - since_req)
    end
  end
  if M.state.last_completed_at_ms > 0 and cooldown_ms > 0 then
    local since_comp = now - M.state.last_completed_at_ms
    if since_comp < cooldown_ms then
      return false, math.ceil(cooldown_ms - since_comp)
    end
  end
  return true, 0
end

---Snapshot summary for status UI and tests.
---@return table
function M.snapshot()
  local s = vim.deepcopy(M.state)
  s.cache_hit_ratio = M.cache_hit_ratio()
  return s
end

function M.reset()
  M.state = initial_state()
end

return M
