---@mod assistit.commands User commands for assistit.nvim
local M = {}

local SUBCOMMANDS = {
  "enable",
  "disable",
  "toggle",
  "status",
  "complete",
  "complete_block",
  "accept",
  "accept_word",
  "accept_line",
  "dismiss",
  "explain",
  "fix",
  "refactor",
  "review",
  "test",
  "doc",
  "optimize",
  "generate",
  "cleanup",
  "index",
  "profile",
  "clear_cache",
  "reset_learning",
}

M._registered = false

---Register all `:AssistIt*` commands idempotently.
function M.setup()
  local api = vim.api.nvim_create_user_command

  api("AssistItEnable", function()
    require("assistit").enable()
  end, { force = true, desc = "Enable assistit.nvim" })

  api("AssistItDisable", function()
    require("assistit").disable()
  end, { force = true, desc = "Disable assistit.nvim" })

  api("AssistItToggle", function()
    require("assistit").toggle()
  end, { force = true, desc = "Toggle assistit.nvim on/off" })

  api("AssistItStatus", function()
    require("assistit").status()
  end, { force = true, desc = "Open AssistIt status, privacy, and latency dashboard" })

  api("AssistItComplete", function()
    require("assistit").complete()
  end, { force = true, desc = "Trigger inline ghost-text completion at cursor" })

  api("AssistItCompleteBlock", function()
    require("assistit").complete_block()
  end, { force = true, desc = "Request a larger multi-line block/function completion" })

  api("AssistItAccept", function()
    require("assistit").accept("full")
  end, { force = true, desc = "Accept active ghost-text suggestion or active diff proposal" })

  api("AssistItAcceptWord", function()
    require("assistit").accept("word")
  end, { force = true, desc = "Accept next word of active ghost-text suggestion" })

  api("AssistItAcceptLine", function()
    require("assistit").accept("line")
  end, { force = true, desc = "Accept next line of active ghost-text suggestion" })

  api("AssistItDismiss", function()
    require("assistit").dismiss()
  end, { force = true, desc = "Dismiss active ghost-text suggestion or preview window" })

  api("AssistItExplain", function(cmd_opts)
    require("assistit").explain(cmd_opts)
  end, { force = true, range = true, desc = "Explain selected code or enclosing function" })

  api("AssistItFix", function(cmd_opts)
    require("assistit").fix(cmd_opts)
  end, { force = true, range = true, desc = "Inspect diagnostic and propose reviewable fix (LSP -> AI)" })

  api("AssistItRefactor", function(cmd_opts)
    require("assistit").refactor(cmd_opts)
  end, { force = true, range = true, desc = "Propose reviewable refactoring for range or function" })

  api("AssistItReview", function(cmd_opts)
    require("assistit").review(cmd_opts)
  end, { force = true, range = true, desc = "Run hybrid static + local AI code & security review" })

  api("AssistItTest", function(cmd_opts)
    require("assistit").test(cmd_opts)
  end, { force = true, range = true, desc = "Generate unit tests matching project conventions" })

  api("AssistItDoc", function(cmd_opts)
    require("assistit").doc(cmd_opts)
  end, { force = true, range = true, desc = "Generate documentation & annotations with diff preview" })

  api("AssistItOptimize", function(cmd_opts)
    require("assistit").optimize(cmd_opts)
  end, { force = true, range = true, desc = "Propose performance & allocation optimizations" })

  api("AssistItGenerate", function(cmd_opts)
    require("assistit").generate(cmd_opts.args)
  end, {
    force = true,
    nargs = "*",
    desc = "Generate code block from natural-language instruction or current comment",
  })

  api("AssistItCleanup", function()
    require("assistit").cleanup()
  end, { force = true, desc = "Run safe deterministic cleanup (remove duplicate imports & trailing spaces)" })

  api("AssistItIndex", function()
    require("assistit").index()
  end, { force = true, desc = "Build or refresh lightweight incremental project index" })

  api("AssistItProfile", function(cmd_opts)
    require("assistit").set_profile(cmd_opts.args)
  end, {
    force = true,
    nargs = 1,
    complete = function()
      return { "ultra_light", "balanced", "performance" }
    end,
    desc = "Switch hardware profile (ultra_light, balanced, performance)",
  })

  api("AssistItClearCache", function()
    require("assistit").clear_cache()
  end, { force = true, desc = "Clear in-memory completion cache" })

  api("AssistItResetLearning", function()
    require("assistit").reset_learning()
  end, { force = true, desc = "Reset local personalization statistics and delete stored JSON" })

  api("AssistIt", function(cmd_opts)
    local parts = vim.split(vim.trim(cmd_opts.args or ""), "%s+", { trimempty = true })
    local sub = (parts[1] or "status"):lower()
    local rest = table.concat(parts, " ", 2)
    local assistit = require("assistit")

    if sub == "enable" then
      assistit.enable()
    elseif sub == "disable" then
      assistit.disable()
    elseif sub == "toggle" then
      assistit.toggle()
    elseif sub == "status" then
      assistit.status()
    elseif sub == "complete" then
      assistit.complete()
    elseif sub == "complete_block" then
      assistit.complete_block()
    elseif sub == "accept" then
      assistit.accept("full")
    elseif sub == "accept_word" then
      assistit.accept("word")
    elseif sub == "accept_line" then
      assistit.accept("line")
    elseif sub == "dismiss" then
      assistit.dismiss()
    elseif sub == "explain" then
      assistit.explain(cmd_opts)
    elseif sub == "fix" then
      assistit.fix(cmd_opts)
    elseif sub == "refactor" then
      assistit.refactor(cmd_opts)
    elseif sub == "review" then
      assistit.review(cmd_opts)
    elseif sub == "test" then
      assistit.test(cmd_opts)
    elseif sub == "doc" then
      assistit.doc(cmd_opts)
    elseif sub == "optimize" then
      assistit.optimize(cmd_opts)
    elseif sub == "generate" then
      assistit.generate(rest)
    elseif sub == "cleanup" then
      assistit.cleanup()
    elseif sub == "index" then
      assistit.index()
    elseif sub == "profile" then
      assistit.set_profile(rest)
    elseif sub == "clear_cache" then
      assistit.clear_cache()
    elseif sub == "reset_learning" then
      assistit.reset_learning()
    else
      vim.notify(string.format("[assistit] Unknown subcommand %q. Try :AssistIt status", sub), vim.log.levels.WARN)
    end
  end, {
    force = true,
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

  M._registered = true
end

return M
