---@mod assistit.completion Predictive ghost-text inline completion engine
local buffer_intel = require("assistit.deterministic.buffer_intel")
local cache = require("assistit.cache")
local context = require("assistit.context")
local ghost = require("assistit.completion.ghost")
local keymaps = require("assistit.completion.keymaps")
local lsp = require("assistit.lsp")
local metrics = require("assistit.metrics")
local personalization = require("assistit.personalization")
local progressive = require("assistit.completion.progressive")
local providers = require("assistit.providers")
local util = require("assistit.util")

local M = {
  ghost = ghost,
  progressive = progressive,
  keymaps = keymaps,
}

M._augroup = nil
M._debounce_timer = nil
M._progress_timer = nil
M._inflight_handle = nil
M._seq = 0
M._cycle_index = 0

---Cancel any in-flight model request and clear pending progress indicator.
function M.cancel_inflight()
  if M._progress_timer then
    M._progress_timer:stop()
  end
  ghost.clear_progress()
  if M._inflight_handle then
    local h = M._inflight_handle
    M._inflight_handle = nil
    if not h:is_cancelled() then
      h:cancel()
      metrics.record_cancelled()
    end
  end
end

---Dismiss active suggestion and record user dismissal for local personalization.
function M.dismiss()
  local active = ghost.get()
  M.cancel_inflight()
  if M._debounce_timer then
    M._debounce_timer:stop()
  end
  if active and active.bufnr and vim.api.nvim_buf_is_valid(active.bufnr) then
    personalization.record_dismissed(vim.bo[active.bufnr].filetype or "")
  end
  ghost.clear()
end

---Determine whether surrounding context justifies an automatic completion trigger.
---@param bufnr integer
---@param row integer 1-indexed
---@param col integer 0-indexed
---@param cfg table
---@return boolean
local function should_auto_trigger(bufnr, row, col, cfg)
  if cfg.completion.respect_popup ~= false and lsp.is_popup_visible() then
    return false
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local before = line:sub(1, col)
  local trimmed_before = util.trim(before)
  local min_chars = cfg.completion.min_line_chars or 1

  if #trimmed_before >= min_chars then
    return true
  end

  -- Even on an empty/indented new line, trigger if previous line is a comment or block/function header
  if row > 1 then
    local prev = util.trim(vim.api.nvim_buf_get_lines(bufnr, row - 2, row - 1, false)[1] or "")
    if
      prev:match("^%-%-")
      or prev:match("^#")
      or prev:match("^//")
      or prev:match("[:{%)]$")
      or prev:match("then$")
      or prev:match("do$")
    then
      return true
    end
  end

  return false
end

---Verify buffer state still matches the exact snapshot when the request was initiated.
---@param snap { bufnr: integer, winid: integer, row: integer, col: integer, changedtick: integer, manual?: boolean }
---@return boolean valid
local function is_snapshot_fresh(snap)
  if not vim.api.nvim_buf_is_valid(snap.bufnr) then
    return false
  end
  if vim.api.nvim_get_current_buf() ~= snap.bufnr then
    return false
  end
  if not snap.manual then
    local mode = vim.api.nvim_get_mode().mode
    if mode:sub(1, 1) ~= "i" then
      return false
    end
  end
  if vim.api.nvim_buf_get_changedtick(snap.bufnr) ~= snap.changedtick then
    return false
  end
  if snap.winid and vim.api.nvim_win_is_valid(snap.winid) then
    local cur = vim.api.nvim_win_get_cursor(snap.winid)
    if cur[1] ~= snap.row or cur[2] ~= snap.col then
      return false
    end
  end
  return true
end

---Execute a completion request (cache -> deterministic Layer A -> local AI Layer C).
---@param opts? { manual?: boolean, block?: boolean, bypass_cache?: boolean, temperature?: number }
function M.trigger(opts)
  opts = opts or {}
  local start_total = util.now_ms()
  local cfg = require("assistit.config").get()

  if not cfg.enabled or not cfg.completion or not cfg.completion.enabled then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  if not util.is_editable_buffer(bufnr, cfg.ignore_buftypes, cfg.ignore_filetypes) then
    return
  end

  if not opts.manual then
    local pos = vim.api.nvim_win_get_cursor(winid)
    if not should_auto_trigger(bufnr, pos[1], pos[2], cfg) then
      return
    end
    local can_run, wait_more = metrics.can_schedule_request(
      cfg.completion.min_interval_ms or 250,
      cfg.completion.cooldown_ms or 120
    )
    if not can_run and wait_more > 0 then
      M.schedule_debounced(wait_more)
      return
    end
  else
    metrics.clear_backoff()
  end

  M.cancel_inflight()

  local ctx = context.extract(bufnr, winid, cfg, {
    prefix_scale = opts.block and 1.5 or 1.0,
    suffix_scale = opts.block and 1.25 or 1.0,
  })
  if ctx.blocked then
    return
  end

  local max_lines = opts.block and (cfg.completion.block_max_lines or 45)
    or personalization.recommended_max_lines(ctx.filetype, cfg.completion.max_lines or 12)
  local max_tokens = opts.block and (cfg.completion.block_max_tokens or 320) or (cfg.completion.max_tokens or 96)

  -- 1. Check LRU exact cache and prefix-continuation cache (0ms latency)
  local cache_key = cache.make_key({
    filetype = ctx.filetype,
    model = cfg.model,
    prefix = ctx.prefix,
    suffix = ctx.suffix,
    extra = opts.block and "block" or "",
  })

  if not opts.bypass_cache then
    local cached_val = cache.global:get(cache_key)
    if cached_val and cached_val ~= "" then
      metrics.record_cache_hit(false)
      metrics.record_plugin_overhead(util.now_ms() - start_total)
      personalization.record_shown(ctx.filetype)
      ghost.show(bufnr, ctx.row, ctx.col, cached_val, { source = "cache", latency_ms = 0 })
      return
    end

    local cont_val = cache.global:find_continuation({
      bufnr = bufnr,
      prev_lines_hash = ctx.prev_lines_hash,
      line_before = ctx.line_before,
      suffix_hash = ctx.suffix_hash,
    })
    if cont_val and cont_val ~= "" then
      metrics.record_cache_hit(true)
      metrics.record_plugin_overhead(util.now_ms() - start_total)
      personalization.record_shown(ctx.filetype)
      ghost.show(bufnr, ctx.row, ctx.col, cont_val, { source = "cache", latency_ms = 0 })
      return
    end
  end

  metrics.record_cache_miss()

  -- 2. Layer A Deterministic Intelligence check
  local model_offline = (cfg.provider == "none") or (not opts.manual and metrics.is_in_backoff())
  if cfg.deterministic and cfg.deterministic.enabled and cfg.deterministic.micro_completions ~= false then
    local micro = buffer_intel.suggest_micro_completion({
      lines = ctx.window_lines,
      row = ctx.window_row,
      col = ctx.col,
      filetype = ctx.filetype,
      allow_identifier_fallback = model_offline and (cfg.completion.deterministic_fallback ~= false),
    })
    if micro and micro ~= "" and not opts.block and not opts.bypass_cache then
      metrics.record_deterministic_hit()
      metrics.record_plugin_overhead(util.now_ms() - start_total)
      personalization.record_shown(ctx.filetype)
      ghost.show(bufnr, ctx.row, ctx.col, micro, { source = "deterministic", latency_ms = 0 })
      if model_offline then
        return
      end
      -- Structural deterministic completions (doc stubs / closing blocks) are sufficient without calling an LLM!
      return
    end
  end

  if model_offline then
    return
  end

  -- 3. Layer C Tiny Local AI Inference
  local provider_mod, req_opts = providers.resolve(cfg, {
    max_tokens = max_tokens,
    max_lines = max_lines,
    temperature = opts.temperature or cfg.completion.temperature or 0.1,
  })
  if not provider_mod then
    return
  end

  M._seq = M._seq + 1
  local req_seq = M._seq
  local raw_cur = vim.api.nvim_win_get_cursor(winid)
  local snapshot = {
    bufnr = bufnr,
    winid = winid,
    row = raw_cur[1],
    col = raw_cur[2],
    insert_row = ctx.row,
    insert_col = ctx.col,
    changedtick = ctx.changedtick,
    manual = opts.manual,
  }

  metrics.record_request_start()

  -- Show unobtrusive indicator only if local inference takes longer than 350ms
  if not M._progress_timer then
    M._progress_timer = util.new_timer()
  end
  M._progress_timer:start(350, function()
    if M._seq == req_seq and M._inflight_handle and not ghost.is_visible(bufnr) and is_snapshot_fresh(snapshot) then
      ghost.show_progress(bufnr, snapshot.row)
    end
  end)

  M._inflight_handle = provider_mod.complete(ctx, req_opts, {
    on_partial = function(partial_text)
      if req_seq ~= M._seq or not partial_text or partial_text == "" then
        return
      end
      if is_snapshot_fresh(snapshot) then
        ghost.show(bufnr, snapshot.insert_row, snapshot.insert_col, partial_text, { source = "ai" })
      end
    end,
    on_done = function(err, res)
      if M._progress_timer then
        M._progress_timer:stop()
      end
      ghost.clear_progress()
      if req_seq == M._seq then
        M._inflight_handle = nil
      end

      if err then
        metrics.record_request_failure(err)
        -- Graceful fallback to deterministic identifier completion when local server is unreachable
        if
          cfg.completion.deterministic_fallback ~= false
          and cfg.deterministic
          and cfg.deterministic.enabled
          and is_snapshot_fresh(snapshot)
        then
          local fallback = buffer_intel.suggest_micro_completion({
            lines = ctx.window_lines,
            row = ctx.window_row,
            col = ctx.col,
            filetype = ctx.filetype,
            allow_identifier_fallback = true,
          })
          if fallback and fallback ~= "" then
            metrics.record_deterministic_hit()
            ghost.show(bufnr, snapshot.insert_row, snapshot.insert_col, fallback, { source = "deterministic", latency_ms = 0 })
            return
          end
        end
        if opts.manual then
          vim.notify("[assistit] " .. err, vim.log.levels.WARN)
        end
        return
      end

      local total_ms = util.now_ms() - start_total
      metrics.record_request_success(res and res.latency_ms or total_ms, total_ms)

      if req_seq ~= M._seq or not is_snapshot_fresh(snapshot) then
        metrics.record_stale_rejected()
        return
      end

      local text = res and res.text or ""
      if text == "" then
        ghost.clear()
        return
      end

      cache.global:set(cache_key, text, {
        bufnr = bufnr,
        prev_lines_hash = ctx.prev_lines_hash,
        line_before = ctx.line_before,
        suffix_hash = ctx.suffix_hash,
        source = "ai",
      })
      personalization.record_shown(ctx.filetype)
      ghost.show(bufnr, snapshot.insert_row, snapshot.insert_col, text, {
        source = "ai",
        latency_ms = res.latency_ms,
      })
    end,
  })
end

---Request an alternative suggestion with slightly higher sampling diversity, bypassing cache.
function M.next_suggestion()
  M._cycle_index = (M._cycle_index % 4) + 1
  local temp = 0.2 + (M._cycle_index * 0.12)
  ghost.clear()
  M.trigger({
    manual = true,
    bypass_cache = true,
    temperature = math.min(0.75, temp),
  })
end

---Schedule a debounced background completion request.
---@param override_delay_ms? integer
function M.schedule_debounced(override_delay_ms)
  local cfg = require("assistit.config").get()
  if not cfg.enabled or not cfg.completion or not cfg.completion.enabled or not cfg.completion.auto_trigger then
    return
  end
  if not M._debounce_timer then
    M._debounce_timer = util.new_timer()
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or ""
  local delay = override_delay_ms
    or metrics.adaptive_debounce_ms(cfg.completion.debounce_ms or 240, personalization.debounce_offset_ms(ft))

  M._debounce_timer:start(delay, function()
    local mode = vim.api.nvim_get_mode().mode
    if mode:sub(1, 1) == "i" then
      M.trigger({ manual = false })
    end
  end)
end

---Handle `TextChangedI`: advance active ghost text in 0ms if typed chars match, else debounce a new request.
local function on_text_changed_i()
  local cfg = require("assistit.config").get()
  if not cfg.enabled or not cfg.completion or not cfg.completion.enabled then
    ghost.clear()
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  if not util.is_editable_buffer(bufnr, cfg.ignore_buftypes, cfg.ignore_filetypes) then
    ghost.clear()
    return
  end

  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if progressive.last_accepted_tick.bufnr == bufnr and progressive.last_accepted_tick.tick == tick then
    return
  end

  -- Fast path: if user typed characters matching the prefix of the active ghost text, slice in 0ms!
  local active = ghost.get()
  if active and active.bufnr == bufnr and active.text ~= "" then
    local pos = vim.api.nvim_win_get_cursor(winid)
    local row, col = pos[1], pos[2]
    if row == active.row and col > active.col then
      local delta_len = col - active.col
      if delta_len < #active.text then
        local cur_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
        local typed = cur_line:sub(active.col + 1, col)
        if active.text:sub(1, delta_len) == typed then
          local sliced = active.text:sub(delta_len + 1)
          metrics.record_cache_hit(true)
          ghost.show(bufnr, row, col, sliced, {
            source = active.source,
            latency_ms = 0,
          })
          return
        end
      end
    end
  end

  ghost.clear()
  M.cancel_inflight()
  M.schedule_debounced()
end

local function on_cursor_moved_i()
  local active = ghost.get()
  if not active then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if progressive.last_accepted_tick.bufnr == bufnr and progressive.last_accepted_tick.tick == tick then
    return
  end
  -- If changedtick changed, this cursor move is part of a character edit handled by TextChangedI
  if active.bufnr == bufnr and active.changedtick and tick ~= active.changedtick then
    return
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  if active.bufnr ~= bufnr or pos[1] ~= active.row or pos[2] ~= active.col then
    ghost.clear()
    M.cancel_inflight()
  end
end

---Initialize completion engine, cache sizing, keymaps, and autocmds.
---@param cfg table
function M.setup(cfg)
  M.teardown()

  local comp_cfg = cfg.completion or {}
  cache.global.max_size = math.max(8, comp_cfg.cache_size or 128)
  cache.global.ttl_ms = math.max(1000, comp_cfg.cache_ttl_ms or 300000)

  keymaps.setup(cfg)

  M._augroup = vim.api.nvim_create_augroup("AssistItCompletion", { clear = true })

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    group = M._augroup,
    callback = on_text_changed_i,
    desc = "assistit: adaptive ghost-text trigger",
  })

  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = M._augroup,
    callback = on_cursor_moved_i,
    desc = "assistit: clear ghost text on cursor jump",
  })

  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = M._augroup,
    callback = function()
      if M._debounce_timer then
        M._debounce_timer:stop()
      end
      M.cancel_inflight()
      ghost.clear()
    end,
    desc = "assistit: clear ghost text on leaving insert mode",
  })

  if comp_cfg.warmup_on_startup and cfg.enabled and cfg.provider ~= "none" then
    providers.warmup(cfg)
  end
end

function M.teardown()
  M.cancel_inflight()
  if M._debounce_timer then
    M._debounce_timer:close()
    M._debounce_timer = nil
  end
  if M._progress_timer then
    M._progress_timer:close()
    M._progress_timer = nil
  end
  ghost.clear()
  keymaps.teardown()
  if M._augroup then
    pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
    M._augroup = nil
  end
end

return M
