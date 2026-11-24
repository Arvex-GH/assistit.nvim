---@mod assistit.deterministic Layer A Deterministic Intelligence coordinator
local autopairs = require("assistit.deterministic.autopairs")
local buffer_intel = require("assistit.deterministic.buffer_intel")
local transforms = require("assistit.deterministic.transforms")

local M = {
  autopairs = autopairs,
  buffer_intel = buffer_intel,
  transforms = transforms,
}

function M.setup(cfg)
  autopairs.setup(cfg)
end

function M.teardown()
  autopairs.teardown()
end

return M
