---@mod assistit.providers.ollama Ollama local inference provider (/api/generate, /api/chat, /api/tags)
local fim = require("assistit.providers.fim")
local transport = require("assistit.providers.transport")
local util = require("assistit.util")

local M = {
  name = "ollama",
}

---@param endpoint string
---@param path string
---@return string
local function join_url(endpoint, path)
  return (endpoint:gsub("/+$", "")) .. path
end

---Build inline completion payload for Ollama `/api/generate`.
---@param ctx table
---@param opts table
---@return table body, table built
function M.build_completion_request(ctx, opts)
  local built = fim.build_prompt(ctx, opts.model, opts.fim_template)
  local body = {
    model = opts.model,
    prompt = built.prompt,
    raw = built.supports_fim,
    stream = opts.stream == true,
    keep_alive = "10m",
    options = {
      num_predict = opts.max_tokens or 96,
      temperature = opts.temperature or 0.1,
      stop = built.stop,
      num_ctx = opts.context_window_tokens or 2048,
    },
  }
  return body, built
end

---Execute FIM/inline completion against Ollama.
---@param ctx table
---@param opts table
---@param callbacks { on_partial?: fun(text: string), on_done: fun(err: string?, res: table?) }
---@return table handle
function M.complete(ctx, opts, callbacks)
  local body, built = M.build_completion_request(ctx, opts)
  local acc = {}

  return transport.request({
    method = "POST",
    url = join_url(opts.endpoint, "/api/generate"),
    headers = opts.headers,
    body = body,
    stream = opts.stream == true,
    timeout_ms = opts.timeout_ms or 8000,
    privacy = opts.privacy,
  }, {
    on_chunk = function(line)
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and type(decoded) == "table" and type(decoded.response) == "string" then
        acc[#acc + 1] = decoded.response
        if callbacks.on_partial then
          local cleaned = fim.clean_completion(table.concat(acc, ""), ctx, opts.max_lines)
          callbacks.on_partial(cleaned)
        end
      end
    end,
    on_done = function(err, resp)
      if err then
        callbacks.on_done(err, nil)
        return
      end
      if not resp then
        callbacks.on_done("Empty HTTP response from Ollama", nil)
        return
      end
      if resp.status < 200 or resp.status >= 300 then
        local msg = string.format("Ollama returned HTTP %d", resp.status)
        local ok_e, dec_e = pcall(vim.json.decode, resp.body or "")
        if ok_e and type(dec_e) == "table" and dec_e.error then
          msg = msg .. ": " .. tostring(dec_e.error)
        end
        callbacks.on_done(msg, nil)
        return
      end

      local raw_text = ""
      if opts.stream and #acc > 0 then
        raw_text = table.concat(acc, "")
      else
        -- Parse single JSON or NDJSON lines
        local ok, decoded = pcall(vim.json.decode, resp.body or "")
        if ok and type(decoded) == "table" then
          if decoded.error then
            callbacks.on_done("Ollama error: " .. tostring(decoded.error), nil)
            return
          end
          raw_text = type(decoded.response) == "string" and decoded.response or ""
        else
          local parts = {}
          local any_valid = false
          for _, l in ipairs(util.split_lines(resp.body or "")) do
            if util.trim(l) ~= "" then
              local okl, dl = pcall(vim.json.decode, l)
              if okl and type(dl) == "table" and type(dl.response) == "string" then
                any_valid = true
                parts[#parts + 1] = dl.response
              end
            end
          end
          if not any_valid then
            callbacks.on_done("Malformed JSON response from Ollama", nil)
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

---Execute instruction/reasoning task via Ollama `/api/chat`.
---@param prompt_spec { system: string, user: string }
---@param opts table
---@param callbacks { on_partial?: fun(text: string), on_done: fun(err: string?, res: table?) }
---@return table handle
function M.generate(prompt_spec, opts, callbacks)
  local body = {
    model = opts.model,
    stream = opts.stream == true,
    keep_alive = "10m",
    messages = {
      { role = "system", content = prompt_spec.system or "You are a concise local coding assistant." },
      { role = "user", content = prompt_spec.user or "" },
    },
    options = {
      num_predict = opts.max_tokens or 512,
      temperature = opts.temperature or 0.2,
      num_ctx = opts.context_window_tokens or 4096,
    },
  }
  local acc = {}

  return transport.request({
    method = "POST",
    url = join_url(opts.endpoint, "/api/chat"),
    headers = opts.headers,
    body = body,
    stream = opts.stream == true,
    timeout_ms = opts.timeout_ms or 20000,
    privacy = opts.privacy,
  }, {
    on_chunk = function(line)
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and type(decoded) == "table" and type(decoded.message) == "table" and decoded.message.content then
        acc[#acc + 1] = decoded.message.content
        if callbacks.on_partial then
          callbacks.on_partial(table.concat(acc, ""))
        end
      end
    end,
    on_done = function(err, resp)
      if err then
        callbacks.on_done(err, nil)
        return
      end
      if not resp or resp.status < 200 or resp.status >= 300 then
        local code = resp and resp.status or 0
        local detail = ""
        if resp and resp.body then
          local ok_e, dec_e = pcall(vim.json.decode, resp.body)
          if ok_e and type(dec_e) == "table" and dec_e.error then
            detail = ": " .. tostring(dec_e.error)
          end
        end
        callbacks.on_done(string.format("Ollama /api/chat failed (HTTP %d%s)", code, detail), nil)
        return
      end

      local text = ""
      if opts.stream and #acc > 0 then
        text = table.concat(acc, "")
      else
        local ok, decoded = pcall(vim.json.decode, resp.body or "")
        if ok and type(decoded) == "table" then
          if type(decoded.message) == "table" and type(decoded.message.content) == "string" then
            text = decoded.message.content
          elseif type(decoded.response) == "string" then
            text = decoded.response
          end
        else
          callbacks.on_done("Malformed JSON response from Ollama /api/chat", nil)
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

---Verify connection to Ollama and check if configured model is installed locally.
---@param opts table
---@param on_done fun(ok: boolean, message: string, models?: string[])
function M.check_health(opts, on_done)
  transport.request({
    method = "GET",
    url = join_url(opts.endpoint, "/api/tags"),
    headers = opts.headers,
    timeout_ms = 3000,
    privacy = opts.privacy,
  }, {
    on_done = function(err, resp)
      if err then
        on_done(false, err)
        return
      end
      if not resp or resp.status ~= 200 then
        on_done(false, string.format("Ollama returned HTTP %d on /api/tags", resp and resp.status or 0))
        return
      end
      local ok, decoded = pcall(vim.json.decode, resp.body or "")
      if not ok or type(decoded) ~= "table" then
        on_done(false, "Invalid JSON from Ollama /api/tags")
        return
      end
      local available = {}
      local found = false
      local target = (opts.model or ""):lower()
      for _, m in ipairs(decoded.models or {}) do
        if type(m.name) == "string" then
          available[#available + 1] = m.name
          local mn = m.name:lower()
          if mn == target or mn == target .. ":latest" or mn:sub(1, #target + 1) == target .. ":" then
            found = true
          end
        end
      end
      if found then
        on_done(true, string.format("Connected to Ollama (%s ready)", opts.model), available)
      elseif #available == 0 then
        on_done(
          false,
          string.format("Ollama is running at %s, but no models are installed (`ollama pull %s`).", opts.endpoint, opts.model),
          available
        )
      else
        on_done(
          false,
          string.format(
            "Ollama is running, but model %q was not found. Installed: %s",
            opts.model,
            table.concat(available, ", ")
          ),
          available
        )
      end
    end,
  })
end

---Preload model weights into Ollama memory without generating tokens.
---@param opts table
---@param on_done? fun(ok: boolean, msg: string)
function M.warmup(opts, on_done)
  transport.request({
    method = "POST",
    url = join_url(opts.endpoint, "/api/generate"),
    headers = opts.headers,
    body = {
      model = opts.model,
      prompt = "",
      keep_alive = "10m",
    },
    timeout_ms = 15000,
    privacy = opts.privacy,
  }, {
    on_done = function(err, resp)
      local ok = err == nil and resp ~= nil and resp.status >= 200 and resp.status < 300
      if on_done then
        on_done(ok, err or "Model warmed up")
      end
    end,
  })
end

return M
