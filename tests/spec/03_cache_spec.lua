local cache = require("assistit.cache")

T.describe("LRU cache & prefix-continuation slicing", function()
  T.it("evicts least-recently-used entries when max_size is reached", function()
    local c = cache.new(3, 60000)
    c:set("k1", "v1")
    c:set("k2", "v2")
    c:set("k3", "v3")
    -- Touch k1 so k2 becomes least-recently-used
    T.eq(c:get("k1"), "v1")
    c:set("k4", "v4")

    T.eq(c:count(), 3)
    T.eq(c:get("k2"), nil)
    T.eq(c:get("k1"), "v1")
    T.eq(c:get("k3"), "v3")
    T.eq(c:get("k4"), "v4")
  end)

  T.it("produces distinct deterministic keys for different prefixes or suffixes", function()
    local a = cache.make_key({ filetype = "lua", prefix = "local a = ", suffix = "" })
    local b = cache.make_key({ filetype = "lua", prefix = "local a = ", suffix = "\nreturn a" })
    T.neq(a, b)
  end)

  T.it("slices cached completion in 0ms when user continues typing matching prefix", function()
    local c = cache.new(16, 60000)
    c:set("orig", "result = compute(items)\nreturn result", {
      bufnr = 1,
      prev_lines_hash = "h_above",
      line_before = "local ",
      suffix_hash = "h_suf",
      source = "ai",
    })

    local cont = c:find_continuation({
      bufnr = 1,
      prev_lines_hash = "h_above",
      line_before = "local res",
      suffix_hash = "h_suf",
    })
    T.eq(cont, "ult = compute(items)\nreturn result")

    -- Divergent typing returns nil
    local miss = c:find_continuation({
      bufnr = 1,
      prev_lines_hash = "h_above",
      line_before = "local xyz",
      suffix_hash = "h_suf",
    })
    T.eq(miss, nil)
  end)
end)
