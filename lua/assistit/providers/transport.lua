---@mod assistit.providers.transport Async non-blocking HTTP client via vim.system + curl
local metrics = require("assistit.metrics")
local privacy = require("assistit.privacy")
local util = require("assistit.util")

local M = {}

---@type (fun(req: table, callbacks: table): table)?
M._mock_handler = nil

---Register or clear a mock transport handler for deterministic unit tests.
---@param fn? fun(req: table, callbacks: table): table
function M.set_mock(fn)
  M._mock_handler = fn
end

---Send an asynchronous HTTP request.
---@param req { method?: string, url: string, headers?: table<string, string>, body?: table|string, timeout_ms?: integer, stream?: boolean, privacy?: table }
---@param callbacks { on_chunk?: fun(line: string), on_done: fun(err: string?, resp: { status: integer, body: string, latency_ms: number, ttft_ms: number? }?) }
---@return { cancel: fun(self: table), is_cancelled: fun(self: table): boolean }
function M.request(req, callbacks)
  local method = (req.method or "POST"):upper()
  local url = req.url or ""
  local timeout_ms = req.timeout_ms or 8000
  local stream = req.stream == true

  local handle = {
    _cancelled = false,
    _completed = false,
    _proc = nil,
  }

  function handle:is_cancelled()
    return self._cancelled
  end

  function handle:cancel()
    if self._cancelled or self._completed then
      return
    end
    self._cancelled = true
    if self._proc and self._proc.kill then
      pcall(function()
        self._proc:kill("sigterm")
      end)
    end
  end

  -- Enforce privacy guard before touching network or mock
  local allowed, reason = privacy.check_endpoint(url, req.privacy)
  if not allowed then
    vim.schedule(function()
      if not handle._cancelled then
        handle._completed = true
        callbacks.on_done(reason, nil)
      end
    end)
    return handle
  end

  if M._mock_handler then
    return M._mock_handler(req, callbacks, handle)
  end

  if vim.fn.executable("curl") ~= 1 then
    vim.schedule(function()
      if not handle._cancelled then
        handle._completed = true
        callbacks.on_done("`curl` executable not found in PATH. Install curl to connect to local model servers.", nil)
      end
    end)
    return handle
  end

  local payload = nil
  if req.body ~= nil then
    if type(req.body) == "table" then
      local ok, encoded = pcall(vim.json.encode, req.body)
      if not ok then
        vim.schedule(function()
          handle._completed = true
          callbacks.on_done("Failed to encode JSON payload: " .. tostring(encoded), nil)
        end)
        return handle
      end
      payload = encoded
    else
      payload = tostring(req.body)
    end
  end

  local max_time_sec = string.format("%.2f", math.max(0.5, timeout_ms / 1000))
  local connect_sec = string.format("%.2f", math.min(2.5, math.max(0.4, timeout_ms / 2000)))

  local args = {
    "curl",
    "--silent",
    "--show-error",
    "--no-buffer",
    "--connect-timeout",
    connect_sec,
    "--max-time",
    max_time_sec,
    "-X",
    method,
    "-w",
    "\n__ASSISTIT_STATUS__:%{http_code}",
  }

  local headers = req.headers or {}
  if payload and not headers["Content-Type"] then
    headers["Content-Type"] = "application/json"
  end
  for k, v in pairs(headers) do
    args[#args + 1] = "-H"
    args[#args + 1] = k .. ": " .. v
  end

  if payload then
    -- Pass request body over stdin so source code never appears in OS process arguments
    args[#args + 1] = "--data-binary"
    args[#args + 1] = "@-"
  end

  args[#args + 1] = url

  local start_ms = util.now_ms()
  local ttft_ms = nil
  local full_chunks = {}
  local line_buf = ""

  local sys_opts = {
    stdin = payload,
    text = true,
  }

  if stream and callbacks.on_chunk then
    sys_opts.stdout = function(_, data)
      if handle._cancelled or not data then
        return
      end
      if not ttft_ms and util.trim(data) ~= "" then
        ttft_ms = util.now_ms() - start_ms
        metrics.record_ttft(ttft_ms)
      end
      full_chunks[#full_chunks + 1] = data
      line_buf = line_buf .. data
      while true do
        local nl = line_buf:find("\n", 1, true)
        if not nl then
          break
        end
        local one_line = line_buf:sub(1, nl - 1):gsub("\r$", "")
        line_buf = line_buf:sub(nl + 1)
        if one_line ~= "" and not one_line:find("^__ASSISTIT_STATUS__:") then
          vim.schedule(function()
            if not handle._cancelled then
              callbacks.on_chunk(one_line)
            end
          end)
        end
      end
    end
  end

  local ok_spawn, proc = pcall(vim.system, args, sys_opts, function(res)
    local latency_ms = util.now_ms() - start_ms
    vim.schedule(function()
      if handle._cancelled then
        return
      end
      handle._completed = true

      local raw_out = (res.stdout and res.stdout ~= "") and res.stdout or table.concat(full_chunks, "")
      local status_code = 0
      local body = raw_out

      local s_start, _, code_str = raw_out:find("\n__ASSISTIT_STATUS__:(%d+)%s*$")
      if not s_start then
        s_start, _, code_str = raw_out:find("^__ASSISTIT_STATUS__:(%d+)%s*$")
      end
      if s_start and code_str then
        status_code = tonumber(code_str) or 0
        body = raw_out:sub(1, s_start - 1)
      end

      if res.code ~= 0 and status_code == 0 then
        local err_msg = util.trim(res.stderr or "")
        if res.code == 28 then
          err_msg = string.format("Request timed out after %dms (%s)", timeout_ms, url)
        elseif res.code == 7 then
          err_msg = string.format("Could not connect to local model server at %s", url)
        elseif err_msg == "" then
          err_msg = string.format("curl exited with code %d (%s)", res.code, url)
        end
        callbacks.on_done(err_msg, nil)
        return
      end

      callbacks.on_done(nil, {
        status = status_code,
        body = body,
        latency_ms = latency_ms,
        ttft_ms = ttft_ms,
      })
    end)
  end)

  if not ok_spawn then
    vim.schedule(function()
      handle._completed = true
      callbacks.on_done("Failed to spawn curl via vim.system: " .. tostring(proc), nil)
    end)
    return handle
  end

  handle._proc = proc
  return handle
end

return M
