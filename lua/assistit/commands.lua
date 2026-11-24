---@mod assistit.commands Short (:Ai* / :ai*) and full (:AssistIt*) user commands
local M = {}

local SUBCOMMANDS = {
  "s",
  "status",
  "p",
  "profile",
  "m",
  "model",
  "f",
  "fix",
  "e",
  "explain",
  "r",
  "refactor",
  "v",
  "review",
  "t",
  "test",
  "d",
  "doc",
  "o",
  "optimize",
  "g",
  "generate",
  "c",
  "cleanup",
  "i",
  "index",
  "l",
  "latency",
  "cp",
  "complete",
  "cb",
  "complete_block",
  "a",
  "accept",
  "aw",
  "accept_word",
  "al",
  "accept_line",
  "x",
  "dismiss",
  "on",
  "enable",
  "off",
  "disable",
  "tg",
  "toggle",
  "cc",
  "clear_cache",
  "rl",
  "reset_learning",
}

M.SHORT_MAP = {
  Ai = "AssistIt",
  Ais = "AssistItStatus",
  Aip = "AssistItProfile",
  Aim = "AssistItModel",
  Aif = "AssistItFix",
  Aie = "AssistItExplain",
  Air = "AssistItRefactor",
  Aiv = "AssistItReview",
  Ait = "AssistItTest",
  Aid = "AssistItDoc",
  Aio = "AssistItOptimize",
  Aig = "AssistItGenerate",
  Aic = "AssistItCleanup",
  Aii = "AssistItIndex",
  Ail = "AssistItLatency",
  Aicp = "AssistItComplete",
  Aicb = "AssistItCompleteBlock",
  Aia = "AssistItAccept",
  Aiaw = "AssistItAcceptWord",
  Aial = "AssistItAcceptLine",
  Aix = "AssistItDismiss",
  Aion = "AssistItEnable",
  Aioff = "AssistItDisable",
  Aitg = "AssistItToggle",
  Aicc = "AssistItClearCache",
  Airl = "AssistItResetLearning",
}

M._registered = false
M._abbrevs_active = false

local function setup_lowercase_abbrevs(enable)
  for short_cmd, _ in pairs(M.SHORT_MAP) do
    local lhs = short_cmd:lower()
    if enable then
      vim.keymap.set("ca", lhs, function()
        if vim.fn.getcmdtype() ~= ":" then
          return lhs
        end
        local line = vim.fn.getcmdline()
        local pos = vim.fn.getcmdpos()
        local before = line:sub(1, pos - 1)
        if before:match("^%s*[%d%.,%$'<>%%]*%s*" .. lhs .. "$") then
          return short_cmd
        end
        return lhs
      end, { expr = true, replace_keycodes = false, desc = "assistit: :" .. lhs .. " -> :" .. short_cmd })
    elseif M._abbrevs_active then
      pcall(vim.keymap.del, "ca", lhs)
    end
  end
  M._abbrevs_active = enable
end

local function model_completions(arg_lead)
  local cfg_mod = require("assistit.config")
  local items = { "none" }
  for _, entry in ipairs(cfg_mod.RECOMMENDED_MODELS or {}) do
    items[#items + 1] = entry.model
    items[#items + 1] = tostring(entry.id)
  end
  local matches = {}
  for _, item in ipairs(items) do
    if item:find("^" .. vim.pesc(arg_lead)) then
      matches[#matches + 1] = item
    end
  end
  return matches
end

local function profile_completions(arg_lead)
  local items = { "ultra_light", "balanced", "performance", "u", "b", "p" }
  local matches = {}
  for _, item in ipairs(items) do
    if item:find("^" .. vim.pesc(arg_lead)) then
      matches[#matches + 1] = item
    end
  end
  return matches
end

local function dispatch_unified(cmd_opts)
  local parts = vim.split(vim.trim(cmd_opts.args or ""), "%s+", { trimempty = true })
  local sub = (parts[1] or "status"):lower()
  local rest = table.concat(parts, " ", 2)
  local assistit = require("assistit")

  if sub == "on" or sub == "enable" then
    assistit.enable()
  elseif sub == "off" or sub == "disable" then
    assistit.disable()
  elseif sub == "tg" or sub == "toggle" then
    assistit.toggle()
  elseif sub == "s" or sub == "status" then
    assistit.status()
  elseif sub == "l" or sub == "latency" then
    assistit.latency()
  elseif sub == "cp" or sub == "complete" then
    assistit.complete()
  elseif sub == "cb" or sub == "complete_block" then
    assistit.complete_block()
  elseif sub == "a" or sub == "accept" then
    assistit.accept("full")
  elseif sub == "aw" or sub == "accept_word" then
    assistit.accept("word")
  elseif sub == "al" or sub == "accept_line" then
    assistit.accept("line")
  elseif sub == "x" or sub == "dismiss" then
    assistit.dismiss()
  elseif sub == "e" or sub == "explain" then
    assistit.explain(cmd_opts)
  elseif sub == "f" or sub == "fix" then
    assistit.fix(cmd_opts)
  elseif sub == "r" or sub == "refactor" then
    assistit.refactor(cmd_opts)
  elseif sub == "v" or sub == "review" then
    assistit.review(cmd_opts)
  elseif sub == "t" or sub == "test" then
    assistit.test(cmd_opts)
  elseif sub == "d" or sub == "doc" then
    assistit.doc(cmd_opts)
  elseif sub == "o" or sub == "optimize" then
    assistit.optimize(cmd_opts)
  elseif sub == "g" or sub == "generate" then
    assistit.generate(rest)
  elseif sub == "c" or sub == "cleanup" then
    assistit.cleanup()
  elseif sub == "i" or sub == "index" then
    assistit.index()
  elseif sub == "p" or sub == "profile" then
    assistit.set_profile(rest)
  elseif sub == "m" or sub == "model" then
    assistit.set_model(rest)
  elseif sub == "cc" or sub == "clear_cache" then
    assistit.clear_cache()
  elseif sub == "rl" or sub == "reset_learning" then
    assistit.reset_learning()
  else
    vim.notify(string.format("[assistit] Unknown subcommand %q. Try :Ai s or :ais", sub), vim.log.levels.WARN)
  end
end

---Register all short `:Ai*` commands, lowercase `:ai*` abbreviations, and `:AssistIt*` aliases.
---@param cfg? table
function M.setup(cfg)
  local api = vim.api.nvim_create_user_command

  local function register(short_name, long_name, fn, opts)
    local short_opts = vim.tbl_extend("force", { force = true }, opts or {})
    api(short_name, fn, short_opts)
    if long_name then
      local long_opts = vim.tbl_extend("force", { force = true }, opts or {})
      long_opts.desc = (opts and opts.desc or short_name) .. " (alias for :" .. short_name .. ")"
      api(long_name, fn, long_opts)
    end
  end

  register("Aion", "AssistItEnable", function()
    require("assistit").enable()
  end, { desc = "Enable assistit.nvim" })

  register("Aioff", "AssistItDisable", function()
    require("assistit").disable()
  end, { desc = "Disable assistit.nvim" })

  register("Aitg", "AssistItToggle", function()
    require("assistit").toggle()
  end, { desc = "Toggle assistit.nvim on/off" })

  register("Ais", "AssistItStatus", function()
    require("assistit").status()
  end, { desc = "Open AssistIt status, privacy, and latency dashboard" })

  register("Ail", "AssistItLatency", function()
    require("assistit").latency()
  end, { desc = "Show AssistIt latency and cache hit summary" })

  register("Aicp", "AssistItComplete", function()
    require("assistit").complete()
  end, { desc = "Trigger inline ghost-text completion at cursor" })

  register("Aicb", "AssistItCompleteBlock", function()
    require("assistit").complete_block()
  end, { desc = "Request a larger multi-line block/function completion" })

  register("Aia", "AssistItAccept", function()
    require("assistit").accept("full")
  end, { desc = "Accept active ghost-text suggestion or active diff proposal" })

  register("Aiaw", "AssistItAcceptWord", function()
    require("assistit").accept("word")
  end, { desc = "Accept next word of active ghost-text suggestion" })

  register("Aial", "AssistItAcceptLine", function()
    require("assistit").accept("line")
  end, { desc = "Accept next line of active ghost-text suggestion" })

  register("Aix", "AssistItDismiss", function()
    require("assistit").dismiss()
  end, { desc = "Dismiss active ghost-text suggestion or preview window" })

  register("Aie", "AssistItExplain", function(cmd_opts)
    require("assistit").explain(cmd_opts)
  end, { range = true, desc = "Explain selected code or enclosing function" })

  register("Aif", "AssistItFix", function(cmd_opts)
    require("assistit").fix(cmd_opts)
  end, { range = true, desc = "Inspect diagnostic and propose reviewable fix (LSP -> AI)" })

  register("Air", "AssistItRefactor", function(cmd_opts)
    require("assistit").refactor(cmd_opts)
  end, { range = true, desc = "Propose reviewable refactoring for range or function" })

  register("Aiv", "AssistItReview", function(cmd_opts)
    require("assistit").review(cmd_opts)
  end, { range = true, desc = "Run hybrid static + local AI code & security review" })

  register("Ait", "AssistItTest", function(cmd_opts)
    require("assistit").test(cmd_opts)
  end, { range = true, desc = "Generate unit tests matching project conventions" })

  register("Aid", "AssistItDoc", function(cmd_opts)
    require("assistit").doc(cmd_opts)
  end, { range = true, desc = "Generate documentation & annotations with diff preview" })

  register("Aio", "AssistItOptimize", function(cmd_opts)
    require("assistit").optimize(cmd_opts)
  end, { range = true, desc = "Propose performance & allocation optimizations" })

  register("Aig", "AssistItGenerate", function(cmd_opts)
    require("assistit").generate(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Generate code block from natural-language instruction or current comment",
  })

  register("Aic", "AssistItCleanup", function()
    require("assistit").cleanup()
  end, { desc = "Run safe deterministic cleanup (remove duplicate imports & trailing spaces)" })

  register("Aii", "AssistItIndex", function()
    require("assistit").index()
  end, { desc = "Build or refresh lightweight incremental project index" })

  register("Aip", "AssistItProfile", function(cmd_opts)
    require("assistit").set_profile(cmd_opts.args)
  end, {
    nargs = 1,
    complete = profile_completions,
    desc = "Switch hardware profile (ultra_light/u, balanced/b, performance/p)",
  })

  register("Aim", "AssistItModel", function(cmd_opts)
    require("assistit").set_model(cmd_opts.args)
  end, {
    nargs = 1,
    complete = model_completions,
    desc = "Switch active local model (1-10 curated index, model tag, or 'none')",
  })

  register("Aicc", "AssistItClearCache", function()
    require("assistit").clear_cache()
  end, { desc = "Clear in-memory completion cache" })

  register("Airl", "AssistItResetLearning", function()
    require("assistit").reset_learning()
  end, { desc = "Reset local personalization statistics and delete stored JSON" })

  register("Ai", "AssistIt", dispatch_unified, {
    range = true,
    nargs = "*",
    complete = function(arg_lead)
      local matches = {}
      for _, s in ipairs(SUBCOMMANDS) do
        if s:find("^" .. vim.pesc(arg_lead)) then
          matches[#matches + 1] = s
        end
      end
      return matches
    end,
    desc = "Unified AssistIt command dispatcher",
  })

  local enable_short = true
  if cfg and cfg.short_commands == false then
    enable_short = false
  end
  setup_lowercase_abbrevs(enable_short)

  M._registered = true
end

return M
