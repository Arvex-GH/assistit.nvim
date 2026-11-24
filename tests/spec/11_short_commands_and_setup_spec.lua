local assistit = require("assistit")
local commands = require("assistit.commands")
local config = require("assistit.config")

T.describe("short commands (:Ai* / :ai*), 10-model switcher, & one-click setup scripts", function()
  T.before_each(function()
    assistit.setup({
      profile = "ultra_light",
      provider = "ollama",
      model = "qwen2.5-coder:0.5b",
      short_commands = true,
    })
  end)

  T.it("registers all short :Ai* Ex commands alongside backwards-compatible :AssistIt* aliases", function()
    local user_cmds = vim.api.nvim_get_commands({})
    for short_name, long_name in pairs(commands.SHORT_MAP) do
      T.truthy(user_cmds[short_name], "Missing short command :" .. short_name)
      T.truthy(user_cmds[long_name], "Missing alias command :" .. long_name)
    end
  end)

  T.it("switches profiles via :Aip shorthands (u/b/p) and switches all 10 curated models via :Aim", function()
    T.eq(#config.RECOMMENDED_MODELS, 10)

    vim.cmd("Aip b")
    T.eq(config.get().profile, "balanced")

    vim.cmd("Aip p")
    T.eq(config.get().profile, "performance")

    vim.cmd("Aip u")
    T.eq(config.get().profile, "ultra_light")

    -- Curated model #10 -> qwen2.5-coder:7b + performance profile
    vim.cmd("Aim 10")
    T.eq(config.get().model, "qwen2.5-coder:7b")
    T.eq(config.get().profile, "performance")

    -- Offline mode (#0 / none)
    vim.cmd("Aim 0")
    T.eq(config.get().provider, "none")

    -- Switching back to curated model #2 restores ollama provider automatically
    vim.cmd("Aim 2")
    T.eq(config.get().provider, "ollama")
    T.eq(config.get().model, "deepseek-coder:1.3b")
    T.eq(config.get().profile, "ultra_light")
  end)

  T.it("expands lowercase :aip / :aim at the command prompt without affecting /search", function()
    local keys = vim.api.nvim_replace_termcodes(":aip p<CR>", true, false, true)
    vim.api.nvim_feedkeys(keys, "mx", false)
    T.eq(config.get().profile, "performance")

    local keys2 = vim.api.nvim_replace_termcodes(":aim 4<CR>", true, false, true)
    vim.api.nvim_feedkeys(keys2, "mx", false)
    T.eq(config.get().model, "qwen2.5-coder:1.5b")
    T.eq(config.get().profile, "balanced")

    -- Ensure /aip search pattern is never rewritten to /Aip
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello", "aip_token = 1" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local search_keys = vim.api.nvim_replace_termcodes("/aip<CR>", true, false, true)
    vim.api.nvim_feedkeys(search_keys, "mx", false)
    T.eq(vim.fn.getreg("/"), "aip")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  T.it("executes setup.sh end-to-end in an isolated XDG directory and validates setup.bat", function()
    local cwd = vim.fn.getcwd()
    local tmp = vim.fn.tempname()
    local cfg_dir = tmp .. "/config/nvim"
    local data_dir = tmp .. "/data/nvim"

    local res = vim.system({
      "bash",
      cwd .. "/setup.sh",
      "--model",
      "4",
      "--skip-pull",
      "--yes",
      "--config-dir",
      cfg_dir,
      "--data-dir",
      data_dir,
    }, { text = true }):wait()

    T.eq(res.code, 0, "setup.sh failed: " .. tostring(res.stderr))
    local gen_cfg = cfg_dir .. "/after/plugin/assistit_setup.lua"
    T.eq(vim.fn.filereadable(gen_cfg), 1)
    T.eq(vim.fn.filereadable(data_dir .. "/site/pack/assistit/start/assistit.nvim/doc/tags"), 1)

    -- Boot a fresh headless Neovim using those isolated XDG dirs and verify auto-configuration
    local boot = vim.system({
      vim.v.progpath,
      "--headless",
      "+lua io.write(require('assistit.config').get().model .. '|' .. require('assistit.config').get().profile)",
      "+qa!",
    }, {
      text = true,
      env = {
        HOME = tmp,
        XDG_CONFIG_HOME = tmp .. "/config",
        XDG_DATA_HOME = tmp .. "/data",
        XDG_STATE_HOME = tmp .. "/state",
        PATH = os.getenv("PATH"),
      },
    }):wait()
    T.eq(boot.code, 0)
    T.eq(boot.stdout, "qwen2.5-coder:1.5b|balanced")

    vim.fn.delete(tmp, "rf")

    -- Validate setup.bat contains all 10 curated models and valid goto targets
    local bat_lines = vim.fn.readfile(cwd .. "/setup.bat")
    local bat_text = table.concat(bat_lines, "\n")
    for _, entry in ipairs(config.RECOMMENDED_MODELS) do
      T.truthy(
        bat_text:find(entry.model, 1, true),
        "setup.bat missing model " .. entry.model
      )
    end

    local labels = {}
    for _, line in ipairs(bat_lines) do
      local lbl = line:match("^%s*:([%w_]+)%s*$")
      if lbl then
        labels[lbl:lower()] = true
      end
    end
    for _, line in ipairs(bat_lines) do
      local target = line:match("goto%s+([%w_]+)")
      if target and target:lower() ~= "eof" then
        T.truthy(labels[target:lower()], "setup.bat missing label :" .. target)
      end
    end
  end)
end)
