---@mod assistit.privacy Privacy guards, sensitive file filtering, and secret redaction
local util = require("assistit.util")

local M = {}

local PLACEHOLDER_VALUES = {
  [""] = true,
  ["none"] = true,
  ["null"] = true,
  ["nil"] = true,
  ["todo"] = true,
  ["changeme"] = true,
  ["password"] = true,
  ["your_api_key"] = true,
  ["your-api-key"] = true,
  ["example"] = true,
  ["test"] = true,
  ["dummy"] = true,
  ["<redacted_secret>"] = true,
}

---Check if a file path matches sensitive/secret file patterns that must never be indexed or sent.
---@param filepath string?
---@param blocked_patterns? string[]
---@return boolean blocked
---@return string? reason
function M.is_sensitive_file(filepath, blocked_patterns)
  if not filepath or filepath == "" then
    return false, nil
  end
  local normalized = filepath:gsub("\\", "/")
  local basename = normalized:match("([^/]+)$") or normalized
  local lower_base = basename:lower()
  local lower_path = normalized:lower()

  local patterns = blocked_patterns
    or {
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
    }

  for _, pat in ipairs(patterns) do
    if lower_base:match(pat) or lower_path:match(pat) then
      return true, string.format("file %q matches blocked pattern %q", basename, pat)
    end
  end

  if lower_path:match("/%.ssh/") or lower_path:match("/%.gnupg/") or lower_path:match("/%.aws/credentials") then
    return true, "file resides in sensitive credential directory"
  end

  return false, nil
end

---Redact known token formats, private keys, URI credentials, and secret assignments from text.
---@param text string
---@return string sanitized
---@return integer redactions
function M.redact_secrets(text)
  if type(text) ~= "string" or text == "" then
    return text or "", 0
  end

  local count = 0
  local out = text

  -- 1. PEM private keys (multiline)
  out = out:gsub(
    "%-%-%-%-%-BEGIN [A-Z0-9 ]*PRIVATE KEY%-%-%-%-%-[%s%S]-%-%-%-%-%-END [A-Z0-9 ]*PRIVATE KEY%-%-%-%-%-",
    function()
      count = count + 1
      return "-----BEGIN PRIVATE KEY-----<REDACTED_SECRET>-----END PRIVATE KEY-----"
    end
  )

  -- 2. Well-known API token prefixes (OpenAI, Anthropic, GitHub, GitLab, Slack, Stripe, AWS)
  local token_patterns = {
    "sk%-ant%-[A-Za-z0-9_%-]+",
    "sk%-proj%-[A-Za-z0-9_%-]+",
    "sk%-[A-Za-z0-9]{20,}",
    "ghp_[A-Za-z0-9]{20,}",
    "gho_[A-Za-z0-9]{20,}",
    "ghs_[A-Za-z0-9]{20,}",
    "github_pat_[A-Za-z0-9_]{20,}",
    "glpat%-[A-Za-z0-9_%-]{16,}",
    "xox[baprs]%-[A-Za-z0-9%-]{16,}",
    "sk_live_[A-Za-z0-9]{16,}",
    "rk_live_[A-Za-z0-9]{16,}",
    "AKIA[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]",
  }

  -- Lua patterns don't support `{n,}` repetition quantifiers natively! Use explicit/clean Lua patterns:
  local lua_token_patterns = {
    "sk%-ant%-[A-Za-z0-9_%-]+",
    "sk%-proj%-[A-Za-z0-9_%-]+",
    "ghp_[A-Za-z0-9]+",
    "gho_[A-Za-z0-9]+",
    "ghs_[A-Za-z0-9]+",
    "github_pat_[A-Za-z0-9_]+",
    "glpat%-[A-Za-z0-9_%-]+",
    "xox[baprs]%-[A-Za-z0-9%-]+",
    "sk_live_[A-Za-z0-9]+",
    "rk_live_[A-Za-z0-9]+",
  }
  local _ = token_patterns -- unused table documented above; use exact Lua patterns below

  for _, pat in ipairs(lua_token_patterns) do
    out = out:gsub(pat, function(m)
      if #m >= 16 then
        count = count + 1
        return "<REDACTED_SECRET>"
      end
      return m
    end)
  end

  -- Generic `sk-...` tokens (>= 24 chars)
  out = out:gsub("sk%-[A-Za-z0-9]+", function(m)
    if #m >= 24 then
      count = count + 1
      return "<REDACTED_SECRET>"
    end
    return m
  end)

  -- AWS Access Key IDs (`AKIA` + 16 uppercase/digits = 20 chars)
  out = out:gsub("AKIA[0-9A-Z]+", function(m)
    if #m == 20 then
      count = count + 1
      return "<REDACTED_SECRET>"
    end
    return m
  end)

  -- 3. JWT tokens (three base64url segments starting with eyJ)
  out = out:gsub("eyJ[A-Za-z0-9_%-]+%.eyJ[A-Za-z0-9_%-]+%.[A-Za-z0-9_%-]+", function(m)
    if #m >= 32 then
      count = count + 1
      return "<REDACTED_SECRET>"
    end
    return m
  end)

  -- 4. Bearer headers
  out = out:gsub("([Bb]earer%s+)([A-Za-z0-9_%-%.~+/=]+)", function(prefix, tok)
    if #tok >= 12 and tok ~= "<REDACTED_SECRET>" then
      count = count + 1
      return prefix .. "<REDACTED_SECRET>"
    end
    return prefix .. tok
  end)

  -- 5. Connection URI credentials (`scheme://user:password@host`)
  out = out:gsub("([a-zA-Z][a-zA-Z0-9%+%-%.]*://[^/:%s\"'@]+:)([^@%s\"']+)(@)", function(pre, secret, at)
    if secret ~= "<REDACTED_SECRET>" and #secret >= 3 then
      count = count + 1
      return pre .. "<REDACTED_SECRET>" .. at
    end
    return pre .. secret .. at
  end)

  -- 6. Quoted secret assignments (`api_key = "..."`, `password: '...'`, `SECRET_TOKEN="..."`)
  local key_names = {
    "password",
    "passwd",
    "pwd",
    "secret",
    "api_key",
    "apikey",
    "secret_key",
    "private_key",
    "access_token",
    "auth_token",
    "client_secret",
  }

  out = out:gsub("([%w_]+)(%s*[:=]%s*)([\"'])([^\"'\r\n]+)([\"'])", function(ident, sep, q1, val, q2)
    if q1 ~= q2 then
      return ident .. sep .. q1 .. val .. q2
    end
    local lower_ident = ident:lower()
    local matched = false
    for _, k in ipairs(key_names) do
      if lower_ident == k or lower_ident:find(k, 1, true) then
        matched = true
        break
      end
    end
    if matched and #val >= 8 and not PLACEHOLDER_VALUES[val:lower()] and not val:match("^%$%{?[A-Z_]") then
      count = count + 1
      return ident .. sep .. q1 .. "<REDACTED_SECRET>" .. q2
    end
    return ident .. sep .. q1 .. val .. q2
  end)

  return out, count
end

---Verify whether an outbound request to `endpoint` is permitted under active privacy settings.
---@param endpoint string
---@param privacy_cfg? table
---@return boolean allowed
---@return string? reason
function M.check_endpoint(endpoint, privacy_cfg)
  privacy_cfg = privacy_cfg or { local_only = true, allow_remote = false }
  if util.is_local_endpoint(endpoint) then
    return true, nil
  end
  if privacy_cfg.local_only or not privacy_cfg.allow_remote then
    return false,
      string.format(
        "Blocked outbound request to remote endpoint %q (privacy.local_only = true). Only loopback addresses are permitted by default.",
        tostring(endpoint)
      )
  end
  return true, nil
end

---Describe request destination clearly for status displays.
---@param cfg table
---@return { provider: string, endpoint: string, is_local: boolean, mode_label: string }
function M.describe_destination(cfg)
  if not cfg or cfg.provider == "none" then
    return {
      provider = "none",
      endpoint = "none (deterministic offline mode)",
      is_local = true,
      mode_label = "LOCAL OFFLINE (No model requests)",
    }
  end
  local ep = cfg.endpoint or ""
  local is_local = util.is_local_endpoint(ep)
  return {
    provider = cfg.provider,
    endpoint = ep,
    is_local = is_local,
    mode_label = is_local and "LOCAL LOOPBACK ONLY" or "OPT-IN REMOTE ENDPOINT",
  }
end

return M
