---@mod assistit.personalization Local statistical adaptation without neural training
---Stores lightweight interaction counts on local disk only. Never uploads usage data.
local util = require("assistit.util")

local M = {}

local uv = vim.uv or vim.loop

local function default_data()
  return {
    schema_version = 1,
    total_shown = 0,
    total_accepted_full = 0,
    total_accepted_partial = 0,
    total_dismissed = 0,
    accepted_line_sum = 0,
    accepted_samples = 0,
    by_filetype = {},
    frequent_prefixes = {},
  }
end

M.data = default_data()
M._loaded = false
M._dirty = false

---Resolve local JSON storage path.
---@param cfg? table
---@return string
function M.storage_path(cfg)
  cfg = cfg or require("assistit.config").get()
  if cfg.personalization and cfg.personalization.storage_path and cfg.personalization.storage_path ~= "" then
    return cfg.personalization.storage_path
  end
  return vim.fn.stdpath("data") .. "/assistit/personalization.json"
end

local function ensure_ft(ft)
  ft = (ft and ft ~= "") and ft or "unknown"
  if not M.data.by_filetype[ft] then
    M.data.by_filetype[ft] = {
      shown = 0,
      accepted = 0,
      dismissed = 0,
      line_sum = 0,
    }
  end
  return M.data.by_filetype[ft]
end

---Load persisted local preferences if available.
---@param cfg? table
function M.load(cfg)
  cfg = cfg or require("assistit.config").get()
  if not cfg.personalization or not cfg.personalization.enabled then
    return
  end
  local path = M.storage_path(cfg)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size <= 0 or stat.size > 524288 then
    M._loaded = true
    return
  end
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    M._loaded = true
    return
  end
  local raw = uv.fs_read(fd, stat.size, 0) or ""
  uv.fs_close(fd)
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == "table" and decoded.schema_version == 1 then
    M.data = vim.tbl_deep_extend("force", default_data(), decoded)
  end
  M._loaded = true
end

---Persist current statistics to local disk.
---@param cfg? table
---@return boolean ok
function M.save(cfg)
  cfg = cfg or require("assistit.config").get()
  if not cfg.personalization or not cfg.personalization.enabled or not M._dirty then
    return false
  end
  local path = M.storage_path(cfg)
  local dir = vim.fn.fnamemodify(path, ":h")
  pcall(vim.fn.mkdir, dir, "p")
  local ok_enc, raw = pcall(vim.json.encode, M.data)
  if not ok_enc then
    return false
  end
  local fd = uv.fs_open(path, "w", 384) -- 0600 permissions (owner-only read/write!)
  if not fd then
    return false
  end
  uv.fs_write(fd, raw, 0)
  uv.fs_close(fd)
  M._dirty = false
  return true
end

function M.record_shown(filetype)
  local cfg = require("assistit.config").get()
  if not cfg.personalization or not cfg.personalization.enabled then
    return
  end
  M.data.total_shown = M.data.total_shown + 1
  local bucket = ensure_ft(filetype)
  bucket.shown = bucket.shown + 1
  M._dirty = true
end

---@param filetype string
---@param text string
---@param is_partial? boolean
function M.record_accepted(filetype, text, is_partial)
  local cfg = require("assistit.config").get()
  if not cfg.personalization or not cfg.personalization.enabled then
    return
  end
  local line_count = math.max(1, #util.split_lines(text or ""))
  if is_partial then
    M.data.total_accepted_partial = M.data.total_accepted_partial + 1
  else
    M.data.total_accepted_full = M.data.total_accepted_full + 1
  end
  M.data.accepted_line_sum = M.data.accepted_line_sum + line_count
  M.data.accepted_samples = M.data.accepted_samples + 1

  local bucket = ensure_ft(filetype)
  bucket.accepted = bucket.accepted + 1
  bucket.line_sum = bucket.line_sum + line_count

  -- Track short structural hash of accepted snippet (no raw user code stored!), bounded to <= 200 keys
  local sig_hash = util.hash((filetype or "") .. ":" .. util.trim(text or ""):sub(1, 32))
  M.data.frequent_prefixes[sig_hash] = (M.data.frequent_prefixes[sig_hash] or 0) + 1
  local key_count = 0
  for _ in pairs(M.data.frequent_prefixes) do
    key_count = key_count + 1
  end
  if key_count > 200 then
    for k, v in pairs(M.data.frequent_prefixes) do
      if v <= 1 and k ~= sig_hash then
        M.data.frequent_prefixes[k] = nil
        key_count = key_count - 1
        if key_count <= 150 then
          break
        end
      end
    end
  end
  M._dirty = true
end

function M.record_dismissed(filetype)
  local cfg = require("assistit.config").get()
  if not cfg.personalization or not cfg.personalization.enabled then
    return
  end
  M.data.total_dismissed = M.data.total_dismissed + 1
  local bucket = ensure_ft(filetype)
  bucket.dismissed = bucket.dismissed + 1
  M._dirty = true
end

---Compute adaptive debounce delta (ms) based on local acceptance patterns for `filetype`.
---@param filetype string
---@return integer offset_ms
function M.debounce_offset_ms(filetype)
  local cfg = require("assistit.config").get()
  if not cfg.personalization or not cfg.personalization.enabled or not cfg.personalization.adapt_debounce then
    return 0
  end
  local bucket = M.data.by_filetype[filetype or ""]
  if not bucket then
    return 0
  end
  local decisions = bucket.accepted + bucket.dismissed
  if decisions < 6 then
    return 0
  end
  local rate = bucket.accepted / decisions
  if rate >= 0.55 then
    return -25
  elseif rate <= 0.15 then
    return 65
  end
  return 0
end

---Compute adaptive max_lines cap based on preferred completion lengths in `filetype`.
---@param filetype string
---@param base_max_lines integer
---@return integer
function M.recommended_max_lines(filetype, base_max_lines)
  local cfg = require("assistit.config").get()
  if not cfg.personalization or not cfg.personalization.enabled or not cfg.personalization.adapt_length then
    return base_max_lines
  end
  local bucket = M.data.by_filetype[filetype or ""]
  if not bucket or bucket.accepted < 6 then
    return base_max_lines
  end
  local avg_lines = bucket.line_sum / bucket.accepted
  -- Allow headroom (2.5x average accepted length, minimum 3 lines, never exceeding base_max_lines)
  local adapted = math.ceil(avg_lines * 2.5)
  return math.floor(util.clamp(adapted, math.min(3, base_max_lines), base_max_lines))
end

---Reset all learned local statistics and remove stored JSON file.
---@param cfg? table
function M.reset(cfg)
  M.data = default_data()
  M._dirty = false
  local path = M.storage_path(cfg)
  if uv.fs_stat(path) then
    pcall(uv.fs_unlink, path)
  end
end

---Explain what personalization stores and return current summary.
---@param cfg? table
---@return table
function M.inspect(cfg)
  local total_acc = M.data.total_accepted_full + M.data.total_accepted_partial
  local avg_lines = M.data.accepted_samples > 0 and (M.data.accepted_line_sum / M.data.accepted_samples) or 0
  return {
    storage_path = M.storage_path(cfg),
    trains_neural_weights = false,
    uploads_data = false,
    stores = "Aggregate counts (shown/accepted/dismissed), per-filetype line-length averages, and 8-char non-reversible snippet hashes with 0600 permissions.",
    total_shown = M.data.total_shown,
    total_accepted_full = M.data.total_accepted_full,
    total_accepted_partial = M.data.total_accepted_partial,
    total_dismissed = M.data.total_dismissed,
    acceptance_rate = M.data.total_shown > 0 and (total_acc / M.data.total_shown) or 0,
    avg_accepted_lines = avg_lines,
    by_filetype = vim.deepcopy(M.data.by_filetype),
  }
end

return M
