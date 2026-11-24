---@mod assistit.completion.keymaps Non-intrusive insert-mode keymaps with popup & fallback preservation
local ghost = require("assistit.completion.ghost")
local lsp = require("assistit.lsp")

local M = {}

M._saved_maps = {}
M._installed_lhs = {}

---Restore a previously saved mapping descriptor retrieved via `maparg(..., true)`.
---@param map table
local function restore_map(map)
  if not map or vim.tbl_isempty(map) or not map.lhs then
    return
  end
  local opts = {
    noremap = map.noremap == 1,
    silent = map.silent == 1,
    expr = map.expr == 1,
    nowait = map.nowait == 1,
    desc = map.desc,
  }
  if map.buffer and map.buffer ~= 0 then
    opts.buffer = map.buffer
  end
  if map.callback then
    pcall(vim.keymap.set, map.mode or "i", map.lhs, map.callback, opts)
  elseif map.rhs then
    pcall(vim.keymap.set, map.mode or "i", map.lhs, map.rhs, opts)
  end
end

---Invoke fallback mapping or return native `lhs` keycodes.
---@param lhs string
---@param saved table?
---@return string
local function fallback_keys(lhs, saved)
  if saved and not vim.tbl_isempty(saved) then
    if saved.callback then
      if saved.expr == 1 then
        local ok, res = pcall(saved.callback)
        if ok and type(res) == "string" then
          return res
        end
      else
        vim.schedule(function()
          pcall(saved.callback)
        end)
        return ""
      end
    elseif type(saved.rhs) == "string" and saved.rhs ~= "" then
      return saved.rhs
    end
  end
  return lhs
end

---Bind a conditional `{ expr = true }` insert keymap that yields to popups and existing mappings.
---@param lhs string?
---@param condition fun(cfg: table): boolean
---@param cmd_expr string `<Cmd>...<CR>` expression to execute when active
---@param desc string
local function bind_conditional(lhs, condition, cmd_expr, desc)
  if type(lhs) ~= "string" or lhs == "" then
    return
  end
  local prior = vim.fn.maparg(lhs, "i", false, true)
  M._saved_maps[lhs] = prior
  M._installed_lhs[#M._installed_lhs + 1] = lhs

  vim.keymap.set("i", lhs, function()
    local cfg = require("assistit.config").get()
    if not cfg.enabled or not cfg.completion or not cfg.completion.enabled then
      return fallback_keys(lhs, prior)
    end
    if cfg.completion.respect_popup ~= false and lsp.is_popup_visible() then
      return fallback_keys(lhs, prior)
    end
    if condition(cfg) then
      return cmd_expr
    end
    return fallback_keys(lhs, prior)
  end, {
    expr = true,
    noremap = true,
    silent = true,
    replace_keycodes = true,
    desc = desc,
  })
end

---Register `<Plug>` mappings unconditionally so users can compose custom mappings even with `keymaps.enabled = false`.
function M.register_plug_mappings()
  vim.keymap.set("i", "<Plug>(assistit-accept)", function()
    if ghost.is_visible() then
      return "<Cmd>lua require('assistit.completion.progressive').accept('full')<CR>"
    end
    return ""
  end, { expr = true, silent = true, replace_keycodes = true, desc = "assistit: accept suggestion" })

  vim.keymap.set("i", "<Plug>(assistit-accept-word)", function()
    if ghost.is_visible() then
      return "<Cmd>lua require('assistit.completion.progressive').accept('word')<CR>"
    end
    return ""
  end, { expr = true, silent = true, replace_keycodes = true, desc = "assistit: accept next word" })

  vim.keymap.set("i", "<Plug>(assistit-accept-line)", function()
    if ghost.is_visible() then
      return "<Cmd>lua require('assistit.completion.progressive').accept('line')<CR>"
    end
    return ""
  end, { expr = true, silent = true, replace_keycodes = true, desc = "assistit: accept next line" })

  vim.keymap.set("i", "<Plug>(assistit-dismiss)", function()
    if ghost.is_visible() then
      return "<Cmd>lua require('assistit.completion').dismiss()<CR>"
    end
    return ""
  end, { expr = true, silent = true, replace_keycodes = true, desc = "assistit: dismiss suggestion" })

  vim.keymap.set(
    "i",
    "<Plug>(assistit-next)",
    "<Cmd>lua require('assistit.completion').next_suggestion()<CR>",
    { silent = true, desc = "assistit: request alternative suggestion" }
  )

  vim.keymap.set(
    "i",
    "<Plug>(assistit-complete-block)",
    "<Cmd>lua require('assistit.completion').trigger({ block = true, manual = true })<CR>",
    { silent = true, desc = "assistit: request multi-line block completion" }
  )
end

---Build the `<Cmd>` sequence for dismissal.
---@param km table
---@return string
local function dismiss_cmd(km)
  if km.esc_passthrough and km.dismiss == "<Esc>" then
    return "<Cmd>lua require('assistit.completion').dismiss()<CR><Esc>"
  end
  return "<Cmd>lua require('assistit.completion').dismiss()<CR>"
end

---Install configured completion keymaps.
---@param cfg table
function M.setup(cfg)
  M.teardown()
  M.register_plug_mappings()

  local km = cfg.completion and cfg.completion.keymaps
  if not km or km.enabled == false then
    return
  end

  local when_visible = function()
    return ghost.is_visible()
  end

  bind_conditional(
    km.accept,
    when_visible,
    "<Cmd>lua require('assistit.completion.progressive').accept('full')<CR>",
    "assistit: accept full suggestion"
  )

  bind_conditional(
    km.accept_word,
    when_visible,
    "<Cmd>lua require('assistit.completion.progressive').accept('word')<CR>",
    "assistit: accept next word"
  )

  if km.accept_word_alt and km.accept_word_alt ~= km.accept_word then
    bind_conditional(
      km.accept_word_alt,
      when_visible,
      "<Cmd>lua require('assistit.completion.progressive').accept('word')<CR>",
      "assistit: accept next word (alt)"
    )
  end

  bind_conditional(
    km.accept_line,
    when_visible,
    "<Cmd>lua require('assistit.completion.progressive').accept('line')<CR>",
    "assistit: accept next line"
  )

  if km.dismiss and km.dismiss ~= "" then
    bind_conditional(km.dismiss, when_visible, dismiss_cmd(km), "assistit: dismiss suggestion")
  end

  if km.next_suggestion and km.next_suggestion ~= "" then
    bind_conditional(
      km.next_suggestion,
      function()
        return true
      end,
      "<Cmd>lua require('assistit.completion').next_suggestion()<CR>",
      "assistit: request another suggestion"
    )
  end

  if km.complete_block and km.complete_block ~= "" then
    bind_conditional(
      km.complete_block,
      function()
        return true
      end,
      "<Cmd>lua require('assistit.completion').trigger({ block = true, manual = true })<CR>",
      "assistit: request larger block completion"
    )
  end
end

function M.teardown()
  for _, lhs in ipairs(M._installed_lhs) do
    pcall(vim.keymap.del, "i", lhs)
    if M._saved_maps[lhs] then
      restore_map(M._saved_maps[lhs])
    end
  end
  M._installed_lhs = {}
  M._saved_maps = {}
end

return M
