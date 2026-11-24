---@mod assistit.providers.openai_compat OpenAI-compatible local server provider (/v1/completions, /v1/chat/completions)
local fim = require("assistit.providers.fim")
local transport = require("assistit.providers.transport")
local util = require("assistit.util")

local M = {
  name = "openai_compat",
}

local function join_url(endpoint, path)
  local clean = endpoint:gsub("/+$", "")
  -- If user configured `http://127.0.0.1:1234/v1`, avoid duplicating `/v1/v1/...`
  if clean:match("/v1$") and path:match("^/v1/") then
    return clean .. path:sub(4)
  end
  return clean .. path
end

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

---Build `/v1/completions` or `/v1/chat/completions` completion request.
---@param ctx table
---@param opts table
---@param use_chat_fallback? boolean
---@return string path, table body, table built
function M.build_completion_request(ctx, opts, use_chat_fallback)
  local built = fim.build_prompt(ctx, opts.model, use_chat_fallback and "prompt" or opts.fim_template)
  if use_chat_fallback or not built.supports_fim then
    return "/v1/chat/completions",
      {
        model = opts.model,
        stream = opts.stream == true,
        max_tokens = opts.max_tokens or 96,
        temperature = opts.temperature or 0.1,
        stop = built.stop,
        messages = {
          {
            role = "system",
            content = "You are an inline code completion engine. Output ONLY raw code to insert at <CURSOR>, without markdown fences or prose.",
          },
          {
            role = "user",
            content = M.TEMPLATES_PROMPT(ctx),
          },
        },
      },
      built
  end

  return "/v1/completions",
    {
      model = opts.model,
      prompt = built.prompt,
      max_tokens = opts.max_tokens or 96,
      temperature = opts.temperature or 0.1,
      stream = opts.stream == true,
      stop = built.stop,
    },
    built
end

function M.TEMPLATES_PROMPT(ctx)
  local full_prefix = ctx.prefix or ""
  if ctx.extra and ctx.extra ~= "" then
    full_prefix = ctx.extra .. "\n" .. full_prefix
  end
  return fim.TEMPLATES.prompt.format(full_prefix, ctx.suffix or "", ctx.language)
end

---Execute inline completion against an OpenAI-compatible local server.
---@param ctx table
---@param opts table
---@param callbacks { on_partial?: fun(text: string), on_done: fun(err: string?, res: table?) }
---@param _chat_fallback? boolean
---@return table handle
function M.complete(ctx, opts, callbacks, _chat_fallback)
  local path, body, built = M.build_completion_request(ctx, opts, _chat_fallback)
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
      local d = parse_sse_json(line)
      if d and type(d.choices) == "table" and d.choices[1] then
        local c1 = d.choices[1]
        local tok = c1.text or (type(c1.delta) == "table" and c1.delta.content)
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
        callbacks.on_done("Empty response from OpenAI-compatible server", nil)
        return
      end

      if
        (resp.status == 404 or resp.status == 405 or resp.status == 501)
        and path == "/v1/completions"
        and not _chat_fallback
      then
        M.complete(ctx, opts, callbacks, true)
        return
      end

      if resp.status < 200 or resp.status >= 300 then
        callbacks.on_done(string.format("OpenAI-compatible server returned HTTP %d on %s", resp.status, path), nil)
        return
      end

      local raw_text = ""
      if opts.stream and #acc > 0 then
        raw_text = table.concat(acc, "")
      else
        local ok, decoded = pcall(vim.json.decode, resp.body or "")
        if ok and type(decoded) == "table" and type(decoded.choices) == "table" and decoded.choices[1] then
          local c1 = decoded.choices[1]
          raw_text = c1.text or (type(c1.message) == "table" and c1.message.content) or ""
        else
          callbacks.on_done("Malformed JSON response from OpenAI-compatible server", nil)
          return
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

---Execute instruction/reasoning task via `/v1/chat/completions`.
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
          string.format("OpenAI-compatible /v1/chat/completions failed (HTTP %d)", resp and resp.status or 0),
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
          callbacks.on_done("Malformed JSON from OpenAI-compatible /v1/chat/completions", nil)
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

function M.check_health(opts, on_done)
  transport.request({
    method = "GET",
    url = join_url(opts.endpoint, "/v1/models"),
    headers = opts.headers,
    timeout_ms = 3000,
    privacy = opts.privacy,
  }, {
    on_done = function(err, resp)
      if err then
        on_done(false, err)
        return
      end
      if not resp or resp.status < 200 or resp.status >= 300 then
        on_done(false, string.format("OpenAI-compatible /v1/models returned HTTP %d", resp and resp.status or 0))
        return
      end
      on_done(true, string.format("Connected to OpenAI-compatible endpoint at %s", opts.endpoint))
    end,
  })
end

function M.warmup(opts, on_done)
  M.check_health(opts, function(ok, msg)
    if on_done then
      on_done(ok, msg)
    end
  end)
end

return M
