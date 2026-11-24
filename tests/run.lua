---Headless Neovim test runner for assistit.nvim
---Run with: nvim --headless -u NONE -l tests/run.lua
---Or:       nvim --headless -u NONE --cmd "set rtp+=." -c "luafile tests/run.lua"

local cwd = vim.fn.getcwd()
vim.opt.rtp:prepend(cwd)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

local T = {
  suites = {},
  current_suite = nil,
  passed = 0,
  failed = 0,
  failures = {},
  mock_proc = nil,
}

function T.describe(name, fn)
  local suite = {
    name = name,
    tests = {},
    before_each = nil,
    after_each = nil,
  }
  T.suites[#T.suites + 1] = suite
  local prev = T.current_suite
  T.current_suite = suite
  fn()
  T.current_suite = prev
end

function T.before_each(fn)
  assert(T.current_suite, "before_each must be inside describe()")
  T.current_suite.before_each = fn
end

function T.after_each(fn)
  assert(T.current_suite, "after_each must be inside describe()")
  T.current_suite.after_each = fn
end

function T.it(name, fn)
  assert(T.current_suite, "it() must be inside describe()")
  T.current_suite.tests[#T.current_suite.tests + 1] = {
    name = name,
    fn = fn,
  }
end

function T.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(
      string.format(
        "%s\n  Expected: %s\n  Actual:   %s",
        msg or "Values are not equal",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function T.neq(actual, unexpected, msg)
  if vim.deep_equal(actual, unexpected) then
    error(string.format("%s\n  Did not expect: %s", msg or "Values should differ", vim.inspect(actual)), 2)
  end
end

function T.truthy(val, msg)
  if not val then
    error(string.format("%s (got %s)", msg or "Expected truthy value", vim.inspect(val)), 2)
  end
end

function T.falsy(val, msg)
  if val then
    error(string.format("%s (got %s)", msg or "Expected falsy value", vim.inspect(val)), 2)
  end
end

function T.matches(str, pattern, msg)
  if type(str) ~= "string" or not str:find(pattern) then
    error(
      string.format(
        "%s\n  Pattern: %q\n  String:  %q",
        msg or "String did not match pattern",
        tostring(pattern),
        tostring(str)
      ),
      2
    )
  end
end

function T.wait_until(timeout_ms, pred, msg)
  local ok = vim.wait(timeout_ms or 3000, pred, 15)
  if not ok then
    error(msg or string.format("Timed out after %dms waiting for condition", timeout_ms or 3000), 2)
  end
end

_G.T = T

---Start local Python mock inference server on an ephemeral port if python3 is available.
local function start_mock_server()
  if vim.fn.executable("python3") ~= 1 then
    return nil
  end
  local port = nil
  local proc = vim.system({ "python3", cwd .. "/tests/helpers/mock_server.py", "0" }, {
    text = true,
    stdout = function(_, data)
      if data and not port then
        local p = data:match("READY%s+(%d+)")
        if p then
          port = tonumber(p)
        end
      end
    end,
  })
  vim.wait(3000, function()
    return port ~= nil
  end, 15)
  T.mock_proc = proc
  return port
end

local function stop_mock_server()
  if T.mock_proc then
    pcall(function()
      T.mock_proc:kill("sigterm")
    end)
    T.mock_proc = nil
  end
end

local function out(line)
  io.stdout:write(line .. "\n")
  io.stdout:flush()
end

local ok_boot, boot_err = xpcall(function()
  vim.cmd("runtime plugin/assistit.lua")
  _G.ASSISTIT_TEST_PORT = start_mock_server()
  out(string.format("=== assistit.nvim Test Suite (Neovim %s, mock port: %s) ===", tostring(vim.version()), tostring(_G.ASSISTIT_TEST_PORT)))

  local filter = os.getenv("ASSISTIT_SPEC")
  local spec_files = vim.fn.glob(cwd .. "/tests/spec/*_spec.lua", false, true)
  table.sort(spec_files)

  for _, file in ipairs(spec_files) do
    if not filter or file:find(filter, 1, true) then
      dofile(file)
    end
  end

  for _, suite in ipairs(T.suites) do
    out("\n[" .. suite.name .. "]")
    for _, test in ipairs(suite.tests) do
      local ok_run, err_msg = xpcall(function()
        if suite.before_each then
          suite.before_each()
        end
        test.fn()
        if suite.after_each then
          suite.after_each()
        end
      end, debug.traceback)

      if suite.after_each and not ok_run then
        pcall(suite.after_each)
      end

      if ok_run then
        T.passed = T.passed + 1
        out("  PASS  " .. test.name)
      else
        T.failed = T.failed + 1
        T.failures[#T.failures + 1] = {
          suite = suite.name,
          test = test.name,
          err = err_msg,
        }
        out("  FAIL  " .. test.name)
      end
    end
  end
end, debug.traceback)

stop_mock_server()

if not ok_boot then
  out("\nFATAL RUNNER ERROR:\n" .. tostring(boot_err))
  vim.cmd("cq 1")
end

out(string.format("\n=== Summary: %d passed, %d failed ===", T.passed, T.failed))

if T.failed > 0 then
  for i, f in ipairs(T.failures) do
    out(string.format("\n--- Failure #%d: [%s] %s ---\n%s", i, f.suite, f.test, f.err))
  end
  vim.cmd("cq 1")
end

vim.cmd("qa!")
