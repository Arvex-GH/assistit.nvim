local config = require("assistit.config")
local context = require("assistit.context")
local index = require("assistit.context.index")

T.describe("context engine, Tree-sitter scope, & incremental project index", function()
  T.it("enforces strict prefix/suffix budgets, extracts Tree-sitter scope, and redacts secrets", function()
    local _, cfg = config.setup({
      provider = "none",
      context = {
        max_prefix_chars = 160,
        max_suffix_chars = 90,
        max_extra_chars = 240,
      },
    })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "lua"
    vim.api.nvim_set_current_buf(buf)

    local lines = {
      'local util = require("assistit.util")',
      'local api_key = "sk-proj-SecretKeyShouldNeverLeak123456789"',
      "function compute_metrics(items)",
    }
    for i = 1, 20 do
      lines[#lines + 1] = string.format("  local step_%d = items[%d] or 0", i, i)
    end
    lines[#lines + 1] = "  local total = "
    lines[#lines + 1] = "  return total"
    lines[#lines + 1] = "end"

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local cursor_row = #lines - 2
    vim.api.nvim_win_set_cursor(0, { cursor_row, #"  local total = " })

    local ctx = context.extract(buf, 0, cfg)
    T.falsy(ctx.blocked)
    T.truthy(#ctx.prefix <= 165, "Prefix exceeded budget: " .. #ctx.prefix)
    T.truthy(#ctx.suffix <= 95, "Suffix exceeded budget: " .. #ctx.suffix)
    T.truthy(ctx.scope ~= nil)
    T.matches(ctx.scope.signature, "compute_metrics")
    T.matches(ctx.extra, "imports:")
    T.falsy(ctx.prefix:find("SecretKeyShouldNeverLeak"))
    T.falsy(ctx.extra:find("SecretKeyShouldNeverLeak"))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  T.it("blocks context extraction inside .env and credential files", function()
    local _, cfg = config.setup({ provider = "none" })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "/tmp/test_assistit/.env.local")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "DATABASE_URL=postgres://u:p@localhost/db" })
    vim.api.nvim_set_current_buf(buf)

    local ctx = context.extract(buf, 0, cfg)
    T.truthy(ctx.blocked)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  T.it("indexes project symbols incrementally while ignoring .env, binaries, and gitignore", function()
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/src", "p")
    vim.fn.mkdir(tmpdir .. "/node_modules/pkg", "p")

    vim.fn.writefile({ "ignored_dir/" }, tmpdir .. "/.gitignore")
    vim.fn.mkdir(tmpdir .. "/ignored_dir", "p")
    vim.fn.writefile({ "function should_not_index() end" }, tmpdir .. "/ignored_dir/skip.lua")
    vim.fn.writefile({ "SECRET=1234567890" }, tmpdir .. "/.env")
    vim.fn.writefile({ "function nope() end" }, tmpdir .. "/node_modules/pkg/index.js")
    vim.fn.writefile({
      "function calculate_sensor_average(readings)",
      "  return 42",
      "end",
    }, tmpdir .. "/src/sensors.lua")

    local _, cfg = config.setup({
      profile = "balanced",
      provider = "none",
    })
    index.clear()
    index.build(cfg, { root = tmpdir, sync = true })

    local sum = index.summary()
    T.truthy(sum.indexed)
    T.eq(sum.file_count, 1)
    T.eq(sum.symbol_count, 1)
    T.eq(sum.conventions.naming, "snake_case")

    local matched = index.query_relevant_symbols("sensor_average", nil, 300)
    T.matches(matched, "calculate_sensor_average")

    vim.fn.delete(tmpdir, "rf")
  end)

  T.it("detects language from filetype, unsaved buffer syntax/shebangs, and embedded code blocks", function()
    local _, cfg = config.setup({ provider = "none" })
    local treesitter = require("assistit.lsp.treesitter")

    -- 1. Unsaved / unnamed buffer (`filetype == ""`) with Python code
    local py_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(py_buf)
    vim.api.nvim_buf_set_lines(py_buf, 0, -1, false, {
      "from typing import List",
      "def average_temp(readings: List[float]):",
      "    return ",
    })
    vim.api.nvim_win_set_cursor(0, { 3, 11 })
    local py_ctx = context.extract(py_buf, 0, cfg)
    T.eq(py_ctx.language, "python")
    T.matches(py_ctx.extra, "# language: python")
    vim.api.nvim_buf_delete(py_buf, { force = true })

    -- 2. Unsaved buffer with Rust, Go, TypeScript, and shebang
    local rs_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(rs_buf, 0, -1, false, { "pub fn compute(items: &[i32]) -> i32 {", "    let mut sum = 0;" })
    T.eq((treesitter.detect_language(rs_buf, 1, 4)), "rust")
    vim.api.nvim_buf_delete(rs_buf, { force = true })

    local ts_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(ts_buf, 0, -1, false, { "export interface UserProfile {", "  id: string;", "}" })
    T.eq((treesitter.detect_language(ts_buf, 1, 2)), "typescript")
    vim.api.nvim_buf_delete(ts_buf, { force = true })

    local sh_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(sh_buf, 0, -1, false, { "#!/usr/bin/env bash", "set -euo pipefail" })
    T.eq((treesitter.detect_language(sh_buf, 1, 0)), "bash")
    vim.api.nvim_buf_delete(sh_buf, { force = true })

    -- 3. Embedded code fences inside a Markdown buffer
    local md_buf = vim.api.nvim_create_buf(true, false)
    vim.bo[md_buf].filetype = "markdown"
    vim.api.nvim_set_current_buf(md_buf)
    vim.api.nvim_buf_set_lines(md_buf, 0, -1, false, {
      "# Guide",
      "```python",
      "def greet(name):",
      "    return f'hi {name}'",
      "```",
      "Some markdown prose here.",
      "```rust",
      "fn main() {}",
      "```",
    })
    -- Line 3 (0-indexed row 2) is inside ```python
    T.eq((treesitter.detect_language(md_buf, 2, 0)), "python")
    -- Line 6 (0-indexed row 5) is Markdown prose
    T.eq((treesitter.detect_language(md_buf, 5, 0)), "markdown")
    -- Line 8 (0-indexed row 7) is inside ```rust
    T.eq((treesitter.detect_language(md_buf, 7, 0)), "rust")
    vim.api.nvim_buf_delete(md_buf, { force = true })
  end)
end)
