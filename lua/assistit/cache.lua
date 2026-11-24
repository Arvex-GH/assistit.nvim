---@mod assistit.cache O(1) LRU completion cache with TTL and prefix-continuation slicing
local util = require("assistit.util")

local M = {}

---@class AssistItCacheEntry
---@field key string
---@field value string
---@field meta table?
---@field expires_at number
---@field prev AssistItCacheEntry?
---@field next AssistItCacheEntry?

---@class AssistItCache
---@field max_size integer
---@field ttl_ms integer
---@field size integer
---@field map table<string, AssistItCacheEntry>
---@field head AssistItCacheEntry?
---@field tail AssistItCacheEntry?
---@field continuations table[]
local Cache = {}
Cache.__index = Cache

---Create a new bounded LRU cache instance.
---@param max_size? integer
---@param ttl_ms? integer
---@return AssistItCache
function M.new(max_size, ttl_ms)
  return setmetatable({
    max_size = math.max(1, max_size or 128),
    ttl_ms = math.max(1000, ttl_ms or 300000),
    size = 0,
    map = {},
    head = nil,
    tail = nil,
    continuations = {},
  }, Cache)
end

function Cache:_detach(node)
  if node.prev then
    node.prev.next = node.next
  else
    self.head = node.next
  end
  if node.next then
    node.next.prev = node.prev
  else
    self.tail = node.prev
  end
  node.prev = nil
  node.next = nil
end

function Cache:_attach_front(node)
  node.prev = nil
  node.next = self.head
  if self.head then
    self.head.prev = node
  end
  self.head = node
  if not self.tail then
    self.tail = node
  end
end

---Build a deterministic context key from completion inputs.
---@param parts { filetype: string?, prefix: string, suffix: string?, model: string?, extra: string? }
---@return string
function M.make_key(parts)
  local raw = table.concat({
    parts.filetype or "",
    parts.model or "",
    parts.prefix or "",
    "\0FIM_SEP\0",
    parts.suffix or "",
    "\0EXTRA\0",
    parts.extra or "",
  }, "|")
  return util.hash(raw)
end

---Get an exact cached completion if present and unexpired.
---@param key string
---@return string? value
---@return table? meta
function Cache:get(key)
  local node = self.map[key]
  if not node then
    return nil, nil
  end
  if util.now_ms() > node.expires_at then
    self:_detach(node)
    self.map[key] = nil
    self.size = self.size - 1
    return nil, nil
  end
  self:_detach(node)
  self:_attach_front(node)
  return node.value, node.meta
end

---Store a completion in the LRU cache and register it for prefix-continuation matching.
---@param key string
---@param value string
---@param meta? { bufnr?: integer, prev_lines_hash?: string, line_before?: string, suffix_hash?: string, source?: string }
function Cache:set(key, value, meta)
  if type(value) ~= "string" or value == "" then
    return
  end
  local expires = util.now_ms() + self.ttl_ms
  local existing = self.map[key]
  if existing then
    existing.value = value
    existing.meta = meta
    existing.expires_at = expires
    self:_detach(existing)
    self:_attach_front(existing)
  else
    if self.size >= self.max_size and self.tail then
      local victim = self.tail
      self:_detach(victim)
      self.map[victim.key] = nil
      self.size = self.size - 1
    end
    local node = {
      key = key,
      value = value,
      meta = meta,
      expires_at = expires,
    }
    self.map[key] = node
    self:_attach_front(node)
    self.size = self.size + 1
  end

  if meta and meta.line_before ~= nil and meta.prev_lines_hash and meta.suffix_hash then
    table.insert(self.continuations, 1, {
      bufnr = meta.bufnr,
      prev_lines_hash = meta.prev_lines_hash,
      line_before = meta.line_before,
      suffix_hash = meta.suffix_hash,
      value = value,
      source = meta.source,
      expires_at = expires,
    })
    if #self.continuations > 24 then
      table.remove(self.continuations)
    end
  end
end

---Attempt to satisfy a completion from a previously generated suggestion where the user
---typed characters matching the start of that suggestion on the exact same surrounding lines.
---@param ctx { bufnr?: integer, prev_lines_hash: string, line_before: string, suffix_hash: string }
---@return string? sliced_completion
---@return string? source
function Cache:find_continuation(ctx)
  if not ctx or not ctx.prev_lines_hash or not ctx.suffix_hash or ctx.line_before == nil then
    return nil, nil
  end
  local now = util.now_ms()
  for i = #self.continuations, 1, -1 do
    if now > self.continuations[i].expires_at then
      table.remove(self.continuations, i)
    end
  end

  for _, item in ipairs(self.continuations) do
    if
      (not item.bufnr or not ctx.bufnr or item.bufnr == ctx.bufnr)
      and item.prev_lines_hash == ctx.prev_lines_hash
      and item.suffix_hash == ctx.suffix_hash
      and #ctx.line_before > #item.line_before
      and ctx.line_before:sub(1, #item.line_before) == item.line_before
    then
      local typed_delta = ctx.line_before:sub(#item.line_before + 1)
      if #item.value > #typed_delta and item.value:sub(1, #typed_delta) == typed_delta then
        local remaining = item.value:sub(#typed_delta + 1)
        if remaining ~= "" then
          return remaining, item.source or "cache_continuation"
        end
      end
    end
  end
  return nil, nil
end

function Cache:clear()
  self.map = {}
  self.head = nil
  self.tail = nil
  self.size = 0
  self.continuations = {}
end

function Cache:count()
  return self.size
end

M.global = M.new(128, 300000)

return M
