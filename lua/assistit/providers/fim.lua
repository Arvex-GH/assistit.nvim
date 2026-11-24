---@mod assistit.providers.fim Model-specific FIM templates, stop tokens, and output sanitization
local util = require("assistit.util")

local M = {}

M.TEMPLATES = {
  qwen = {
    name = "qwen",
    supports_fim = true,
    format = function(prefix, suffix)
      return "<|fim_prefix|>" .. prefix .. "<|fim_suffix|>" .. suffix .. "<|fim_middle|>"
    end,
    stop = {
      "<|endoftext|>",
      "<|fim_pad|>",
      "<|fim_prefix|>",
      "<|fim_suffix|>",
      "<|fim_middle|>",
      "<|file_sep|>",
      "<|im_end|>",
    },
  },

  deepseek = {
    name = "deepseek",
    supports_fim = true,
    format = function(prefix, suffix)
      return "<｜fim▁begin｜>" .. prefix .. "<｜fim▁hole｜>" .. suffix .. "<｜fim▁end｜>"
    end,
    stop = {
      "<｜end▁of▁sentence｜>",
      "<｜fim▁begin｜>",
      "<｜fim▁hole｜>",
      "<｜fim▁end｜>",
      "<|EOT|>",
      "<|endoftext|>",
    },
  },

  starcoder = {
    name = "starcoder",
    supports_fim = true,
    format = function(prefix, suffix)
      return "<fim_prefix>" .. prefix .. "<fim_suffix>" .. suffix .. "<fim_middle>"
    end,
    stop = {
      "<|endoftext|>",
      "<fim_pad>",
      "<fim_prefix>",
      "<fim_suffix>",
      "<fim_middle>",
      "<file_sep>",
      "<|file_separator|>",
      "<eos>",
    },
  },

  codellama = {
    name = "codellama",
    supports_fim = true,
    format = function(prefix, suffix)
      return "<PRE> " .. prefix .. " <SUF>" .. suffix .. " <MID>"
    end,
    stop = {
      "<EOT>",
      "</s>",
      "<END>",
      "<PRE>",
      "<SUF>",
      "<MID>",
    },
  },

  codestral = {
    name = "codestral",
    supports_fim = true,
    format = function(prefix, suffix)
      return "[SUFFIX]" .. suffix .. "[PREFIX]" .. prefix
    end,
    stop = {
      "</s>",
      "[INST]",
      "[/INST]",
      "[PREFIX]",
      "[SUFFIX]",
    },
  },

  prompt = {
    name = "prompt",
    supports_fim = false,
    format = function(prefix, suffix, language)
      local lang = language or "code"
      return table.concat({
        "Continue the " .. lang .. " code at <CURSOR>. Output ONLY the exact code to insert at <CURSOR>, with no markdown fences and no explanation.",
        "--- CODE ---",
        prefix .. "<CURSOR>" .. suffix,
        "--- INSERTION AT <CURSOR> ---",
      }, "\n")
    end,
    stop = {
      "---",
      "<CURSOR>",
      "```",
      "<|endoftext|>",
      "<|im_end|>",
      "</s>",
    },
  },
}

---Detect appropriate FIM template family from a model identifier string.
---@param model_name string?
---@param configured_template? string
---@return string template_key
function M.detect_template(model_name, configured_template)
  if configured_template and configured_template ~= "auto" and M.TEMPLATES[configured_template] then
    return configured_template
  end
  local m = (model_name or ""):lower()
  if m:find("qwen", 1, true) or m:find("yi%-coder") then
    return "qwen"
  elseif m:find("deepseek", 1, true) then
    return "deepseek"
  elseif
    m:find("starcoder", 1, true)
    or m:find("santacoder", 1, true)
    or m:find("codegemma", 1, true)
    or m:find("granite%-code")
    or m:find("granite_code")
    or m:find("stable%-code")
    or m:find("mellom", 1, true)
    or m:find("smollm2", 1, true)
  then
    return "starcoder"
  elseif m:find("codellama", 1, true) or m:find("code%-llama") then
    return "codellama"
  elseif m:find("codestral", 1, true) then
    return "codestral"
  end
  return "prompt"
end

---Construct formatted completion prompt and stop token list for `(ctx, model_name, template_opt)`.
---@param ctx { prefix: string, suffix: string?, extra: string?, language: string? }
---@param model_name string
---@param template_opt? string
---@return { template: string, supports_fim: boolean, prompt: string, prefix_with_extra: string, suffix: string, stop: string[] }
function M.build_prompt(ctx, model_name, template_opt)
  local key = M.detect_template(model_name, template_opt)
  local spec = M.TEMPLATES[key] or M.TEMPLATES.prompt

  local full_prefix = ctx.prefix or ""
  if ctx.extra and ctx.extra ~= "" then
    full_prefix = ctx.extra .. "\n" .. full_prefix
  end
  local suffix = ctx.suffix or ""

  local prompt = spec.format(full_prefix, suffix, ctx.language)
  return {
    template = key,
    supports_fim = spec.supports_fim,
    prompt = prompt,
    prefix_with_extra = full_prefix,
    suffix = suffix,
    stop = vim.deepcopy(spec.stop),
  }
end

---Strip special tokens, accidental fences, prefix echo, and suffix overlap from raw model output.
---@param raw string
---@param ctx? { line_before?: string, line_after?: string, suffix?: string }
---@param max_lines? integer
---@return string
function M.clean_completion(raw, ctx, max_lines)
  if type(raw) ~= "string" or raw == "" then
    return ""
  end

  local out = raw:gsub("\r\n", "\n")

  -- 1. Strip any leaked FIM or EOS markers
  local markers = {
    "<|endoftext|>",
    "<|fim_pad|>",
    "<|fim_prefix|>",
    "<|fim_suffix|>",
    "<|fim_middle|>",
    "<|file_sep|>",
    "<|im_end|>",
    "<｜end▁of▁sentence｜>",
    "<｜fim▁begin｜>",
    "<｜fim▁hole｜>",
    "<｜fim▁end｜>",
    "<|EOT|>",
    "<fim_pad>",
    "<fim_prefix>",
    "<fim_suffix>",
    "<fim_middle>",
    "<file_sep>",
    "<EOT>",
    "</s>",
  }
  for _, tok in ipairs(markers) do
    local idx = out:find(tok, 1, true)
    if idx then
      out = out:sub(1, idx - 1)
    end
  end

  -- 2. Strip accidental markdown code fences from prompt-fallback models
  if out:match("^%s*```") then
    out = out:gsub("^%s*```[%w_%-]*\n?", "")
    out = out:gsub("\n?```%s*$", "")
  end

  ctx = ctx or {}
  local line_before = ctx.line_before or ""
  local line_after = ctx.line_after or ""

  -- 3. Remove accidental echo of `line_before` at start of completion
  if line_before ~= "" and #out > #line_before and out:sub(1, #line_before) == line_before then
    out = out:sub(#line_before + 1)
  else
    local trimmed_before = util.trim(line_before)
    if #trimmed_before >= 4 and out:sub(1, #trimmed_before) == trimmed_before then
      out = out:sub(#trimmed_before + 1)
    end
  end

  -- 4. Trim trailing blank-only lines
  out = out:gsub("[\n \t]+$", function(tail)
    -- Preserve single space if completion is just a word + space, otherwise strip trailing newlines/spaces
    if not tail:find("\n", 1, true) and #out <= 24 then
      return tail
    end
    return ""
  end)

  -- 5. Enforce max_lines budget cleanly
  if max_lines and max_lines > 0 then
    local lines = util.split_lines(out)
    if #lines > max_lines then
      local sliced = {}
      for i = 1, max_lines do
        sliced[i] = lines[i]
      end
      out = table.concat(sliced, "\n")
    end
  end

  -- 6. Deduplicate overlap with `line_after` on the cursor line (e.g., closing `)` or `";` already after cursor)
  if line_after ~= "" and out ~= "" then
    local max_overlap = math.min(#out, #line_after)
    for len = max_overlap, 1, -1 do
      if out:sub(#out - len + 1) == line_after:sub(1, len) then
        out = out:sub(1, #out - len)
        break
      end
    end
  end

  -- 7. Deduplicate multi-line suffix overlap if model repeated the first non-empty line of suffix
  if ctx.suffix and ctx.suffix ~= "" and out:find("\n", 1, true) then
    local suf_lines = util.split_lines(ctx.suffix)
    for _, sline in ipairs(suf_lines) do
      local trimmed_suf = util.trim(sline)
      if #trimmed_suf >= 4 then
        local out_lines = util.split_lines(out)
        if #out_lines > 1 and util.trim(out_lines[#out_lines]) == trimmed_suf then
          table.remove(out_lines)
          out = table.concat(out_lines, "\n")
        end
        break
      end
    end
  end

  if util.trim(out) == "" then
    return ""
  end

  return out
end

return M
