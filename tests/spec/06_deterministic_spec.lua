local autopairs = require("assistit.deterministic.autopairs")
local buffer_intel = require("assistit.deterministic.buffer_intel")
local transforms = require("assistit.deterministic.transforms")

T.describe("Layer A deterministic intelligence (zero-model capabilities)", function()
  T.it("computes cursor-aware bracket and quote pairs safely", function()
    local keys1, sp1 = autopairs.compute_action("(", "local x = fn", 12, "lua")
    T.truthy(sp1)
    T.eq(keys1, "()<Left>")

    -- Does not auto-pair right before an identifier character
    local keys2, sp2 = autopairs.compute_action("(", "local x = fn", 10, "lua")
    T.falsy(sp2)
    T.eq(keys2, "(")

    -- Steps over existing closing paren
    local keys3, sp3 = autopairs.compute_action(")", "fn()", 3, "lua")
    T.truthy(sp3)
    T.eq(keys3, "<Right>")

    -- Does not auto-pair apostrophe inside contractions or Rust lifetimes
    local keys4, sp4 = autopairs.compute_action("'", "don", 3, "markdown")
    T.falsy(sp4)
    T.eq(keys4, "'")
  end)

  T.it("detects duplicate imports, unused bindings, tautological conditions, and security issues", function()
    local lines = {
      'local json = require("cjson")',
      'local json2 = require("cjson")',
      'local unused_helper = require("helper")',
      "local never_read = 123",
      "if count == count then",
      '  os.execute("rm -rf " .. user_input)',
      "  return json.encode({})",
      "end",
    }

    local findings = buffer_intel.analyze_lines(lines, {
      filetype = "lua",
      intensity = "deep",
    })

    local by_code = {}
    for _, f in ipairs(findings) do
      by_code[f.code] = f
    end

    T.truthy(by_code["duplicate_import"], "Expected duplicate_import finding")
    T.eq(by_code["duplicate_import"].lnum, 2)
    T.truthy(by_code["unused_import"], "Expected unused_import finding")
    T.truthy(by_code["unused_local"], "Expected unused_local finding")
    T.truthy(by_code["suspicious_conditional"], "Expected suspicious_conditional finding")
    T.truthy(by_code["security_shell_concat"], "Expected security_shell_concat finding")
  end)

  T.it("generates structural micro-completions and offline identifier continuations in <1ms", function()
    local lua_lines = {
      "---",
      "function add_values(alpha, beta)",
      "  return alpha + beta",
      "end",
    }
    local doc_sug = buffer_intel.suggest_micro_completion({
      lines = lua_lines,
      row = 1,
      col = 3,
      filetype = "lua",
    })
    T.matches(doc_sug, "@param alpha")
    T.matches(doc_sug, "@param beta")

    -- Offline identifier continuation
    local id_lines = {
      "local sensor_temperature_celsius = 21.5",
      "print(sensor_temp)",
    }
    local id_sug = buffer_intel.suggest_micro_completion({
      lines = id_lines,
      row = 2,
      col = #"print(sensor_temp",
      filetype = "lua",
      allow_identifier_fallback = true,
    })
    T.eq(id_sug, "erature_celsius")
  end)

  T.it("cleans duplicate imports and trailing whitespace safely", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "python"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "import os   ",
      "import sys",
      "import os",
      "print(os.getcwd(), sys.version)  ",
    })

    local removed = transforms.remove_duplicate_imports(buf)
    local stripped = transforms.strip_trailing_whitespace(buf)
    T.eq(removed, 1)
    T.eq(stripped, 2)

    local final = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    T.eq(final, {
      "import os",
      "import sys",
      "print(os.getcwd(), sys.version)",
    })

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
