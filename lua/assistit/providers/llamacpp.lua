---@mod assistit.providers.llamacpp llama.cpp local server provider (/infill, /completion, /health)
local fim = require("assistit.providers.fim")
local transport = require("assistit.providers.transport")
local util = require("assistit.util")

local M = {
  name = "llamacpp",
}

local function join_url(endpoint, path)
  return (endpoint:gsub("/+$", "")) .. path
end

---Parse SSE `data: {...}` line emitted by llama.cpp streaming endpoints.
---@param line string
---@return table?
local function parse_sse_json(line)
  local payload = line:match("^data:%s*(.+)$") or line
  payload = util.trim(payload)
  if payload == "" or payload == "[DONE]" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, payload)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

---Build request spec for llama.cpp (`use_infill = true` uses `/infill`, otherwise `/completion`).
---@param ctx table
---@param opts table
---@param force_completion_endpoint? boolean
---@return string path, table body, table built
function M.build_completion_request(ctx, opts, force_completion_endpoint)
  local built = fim.build_prompt(ctx, opts.model, opts.fim_template)
  if built.supports_fim and not force_completion_endpoint then
    return "/infill",
      {
        input_prefix = built.prefix_with_extra,
        input_suffix = built.suffix,
        n_predict = opts.max_tokens or 96,
        temperature = opts.temperature or 0.1,
        cache_prompt = true,
        stream = opts.stream == true,
        stop = built.stop,
      },
      built
  end

  return "/completion",
    {
      prompt = built.prompt,
      n_predict = opts.max_tokens or 96,
      temperature = opts.temperature or 0.1,
      cache_prompt = true,
      stream = opts.stream == true,
      stop = built.stop,
    },
    built
end

---Execute inline completion via llama-server `/infill` (or `/completion` fallback).
---@param ctx table
---@param opts table
---@param callbacks { on_partial?: fun(text: string), on_done: fun(err: string?, res: table?) }
---@param _fallback? boolean
---@return table handle
function M.complete(ctx, opts, callbacks, _fallback)
  local path, body, built = M.build_completion_request(ctx, opts, _fallback)
  local acc = {}

  return transport.request({
    method = "POST",
    url = join_url(opts.endpoint, path),
    headers = opts.headers,
    body = body,
    stream = opts.stream == true,
    timeout_ms = opts.timeout_ms or 8000,
    privacy = opts.privacy,
  }, {
    on_chunk = function(line)
      local decoded = parse_sse_json(line)
      if decoded then
        local tok = decoded.content
        if not tok and type(decoded.choices) == "table" and decoded.choices[1] then
          tok = decoded.choices[1].text
        end
        if type(tok) == "string" and tok ~= "" then
          acc[#acc + 1] = tok
          if callbacks.on_partial then
            callbacks.on_partial(fim.clean_completion(table.concat(acc, ""), ctx, opts.max_lines))
          end
        end
      end
    end,
    on_done = function(err, resp)
      if err then
        callbacks.on_done(err, nil)
        return
      end
      if not resp then
        callbacks.on_done("Empty response from llama.cpp server", nil)
        return
      end

      -- If `/infill` is unsupported on this server/model (404/501/400), retry once on `/completion`
      if (resp.status == 404 or resp.status == 501) and path == "/infill" and not _fallback then
        M.complete(ctx, opts, callbacks, true)
        return
      end

      if resp.status < 200 or resp.status >= 300 then
        callbacks.on_done(string.format("llama.cpp returned HTTP %d on %s", resp.status, path), nil)
        return
      end

      local raw_text = ""
      if opts.stream and #acc > 0 then
        raw_text = table.concat(acc, "")
      else
        local ok, decoded = pcall(vim.json.decode, resp.body or "")
        if ok and type(decoded) == "table" then
          if type(decoded.content) == "string" then
            raw_text = decoded.content
          elseif type(decoded.choices) == "table" and decoded.choices[1] and type(decoded.choices[1].text) == "string" then
            raw_text = decoded.choices[1].text
          end
        else
          -- Try SSE body lines if server streamed anyway
          local parts = {}
          local any_sse = false
          for _, l in ipairs(util.split_lines(resp.body or "")) do
            local d = parse_sse_json(l)
            if d and type(d.content) == "string" then
              any_sse = true
              parts[#parts + 1] = d.content
            end
          end
          if not any_sse then
            callbacks.on_done("Malformed JSON response from llama.cpp", nil)
            return
          end
          raw_text = table.concat(parts, "")
        end
      end

      local cleaned = fim.clean_completion(raw_text, ctx, opts.max_lines)
      callbacks.on_done(nil, {
        text = cleaned,
        raw_text = raw_text,
        latency_ms = resp.latency_ms,
        ttft_ms = resp.ttft_ms,
        template = built.template,
      })
    end,
  })
end

---Execute instruction/reasoning task via llama.cpp `/v1/chat/completions` (with `/completion` fallback).
---@param prompt_spec { system: string, user: string }
---@param opts table
---@param callbacks { on_partial?: fun(text: string), on_done: fun(err: string?, res: table?) }
---@return table handle
function M.generate(prompt_spec, opts, callbacks)
  local body = {
    model = opts.model,
    stream = opts.stream == true,
    max_tokens = opts.max_tokens or 512,
    temperature = opts.temperature or 0.2,
    messages = {
      { role = "system", content = prompt_spec.system or "You are a concise local coding assistant." },
      { role = "user", content = prompt_spec.user or "" },
    },
  }
  local acc = {}

  return transport.request({
    method = "POST",
    url = join_url(opts.endpoint, "/v1/chat/completions"),
    headers = opts.headers,
    body = body,
    stream = opts.stream == true,
    timeout_ms = opts.timeout_ms or 20000,
    privacy = opts.privacy,
  }, {
    on_chunk = function(line)
      local d = parse_sse_json(line)
      if d and type(d.choices) == "table" and d.choices[1] then
        local delta = d.choices[1].delta
        if type(delta) == "table" and type(delta.content) == "string" then
          acc[#acc + 1] = delta.content
          if callbacks.on_partial then
            callbacks.on_partial(table.concat(acc, ""))
          end
        end
      end
    end,
    on_done = function(err, resp)
      if err then
        callbacks.on_done(err, nil)
        return
      end
      if not resp or resp.status < 200 or resp.status >= 300 then
        callbacks.on_done(
          string.format("llama.cpp /v1/chat/completions failed (HTTP %d)", resp and resp.status or 0),
          nil
        )
        return
      end

      local text = ""
      if opts.stream and #acc > 0 then
        text = table.concat(acc, "")
      else
        local ok, decoded = pcall(vim.json.decode, resp.body or "")
        if ok and type(decoded) == "table" and type(decoded.choices) == "table" and decoded.choices[1] then
          local msg = decoded.choices[1].message
          text = (type(msg) == "table" and msg.content) or decoded.choices[1].text or ""
        else
          callbacks.on_done("Malformed JSON from llama.cpp /v1/chat/completions", nil)
          return
        end
      end

      callbacks.on_done(nil, {
        text = util.trim(text),
        latency_ms = resp.latency_ms,
      })
    end,
  })
end

---Check llama-server `/health` status.
---@param opts table
---@param on_done fun(ok: boolean, message: string)
function M.check_health(opts, on_done)
  transport.request({
    method = "GET",
    url = join_url(opts.endpoint, "/health"),
    headers = opts.headers,
    timeout_ms = 3000,
    privacy = opts.privacy,
  }, {
    on_done = function(err, resp)
      if err then
        on_done(false, err)
        return
      end
      if not resp then
        on_done(false, "Empty health check response from llama.cpp")
        return
      end
      local ok_j, decoded = pcall(vim.json.decode, resp.body or "")
      local status_field = ok_j and type(decoded) == "table" and decoded.status or nil
      if resp.status == 200 and (status_field == "ok" or status_field == nil) then
        on_done(true, string.format("Connected to llama.cpp server at %s", opts.endpoint))
      elseif resp.status == 503 and status_field then
        on_done(false, string.format("llama.cpp server busy/loading: %s", tostring(status_field)))
      else
        on_done(false, string.format("llama.cpp /health returned HTTP %d", resp.status))
      end
    end,
  })
end

function M.warmup(opts, on_done)
  transport.request({
    method = "POST",
    url = join_url(opts.endpoint, "/completion"),
    headers = opts.headers,
    body = {
      prompt = " ",
      n_predict = 1,
      cache_prompt = true,
    },
    timeout_ms = 12000,
    privacy = opts.privacy,
  }, {
    on_done = function(err, resp)
      local ok = err == nil and resp ~= nil and resp.status >= 200 and resp.status < 300
      if on_done then
        on_done(ok, err or "llama.cpp warmed up")
      end
    end,
  })
end

return M
