---@mod assistit.context.index Lightweight incremental project index
local privacy = require("assistit.privacy")
local util = require("assistit.util")

local M = {}

local uv = vim.uv or vim.loop

local BINARY_EXTENSIONS = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  webp = true,
  ico = true,
  pdf = true,
  zip = true,
  tar = true,
  gz = true,
  xz = true,
  zst = true,
  so = true,
  dylib = true,
  dll = true,
  exe = true,
  o = true,
  a = true,
  pyc = true,
  wasm = true,
  gguf = true,
  bin = true,
  safetensors = true,
  onnx = true,
  ttf = true,
  woff = true,
  woff2 = true,
  mp3 = true,
  mp4 = true,
  sqlite = true,
  db = true,
}

M.state = {
  root = nil,
  indexed = false,
  indexing = false,
  file_count = 0,
  files = {}, -- rel_path -> { mtime: number, symbols: { name: string, kind: string, sig: string }[], is_test: boolean }
  conventions = {
    naming = "snake_case",
    test_framework = nil,
    dependencies = {},
  },
  last_indexed_ms = 0,
}

---Convert a simple `.gitignore` glob pattern into a Lua pattern for fallback directory walking.
---@param glob string
---@return string?
local function gitignore_to_lua_pattern(glob)
  local g = util.trim(glob)
  if g == "" or g:sub(1, 1) == "#" or g:sub(1, 1) == "!" then
    return nil
  end
  g = g:gsub("^/", ""):gsub("/$", "")
  local escaped = g:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")
  escaped = escaped:gsub("%*%*", ".*"):gsub("%*", "[^/]*"):gsub("%?", "[^/]")
  return escaped
end

---Load `.gitignore` patterns from `root/.gitignore` if present.
---@param root string
---@return string[]
local function load_gitignore_patterns(root)
  local path = root .. "/.gitignore"
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > 65536 then
    return {}
  end
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return {}
  end
  local data = uv.fs_read(fd, stat.size, 0) or ""
  uv.fs_close(fd)
  local out = {}
  for _, line in ipairs(util.split_lines(data)) do
    local pat = gitignore_to_lua_pattern(line)
    if pat then
      out[#out + 1] = pat
    end
  end
  return out
end

---Check whether `rel_path` should be ignored based on hidden/binary/sensitive/ignore rules.
---@param rel_path string
---@param ignore_patterns string[]
---@param blocked_patterns string[]
---@return boolean
function M.should_ignore(rel_path, ignore_patterns, blocked_patterns)
  local norm = rel_path:gsub("\\", "/"):gsub("^%./", "")
  if norm == "" then
    return true
  end

  -- Skip hidden files and hidden directories (e.g. .git/, .env, .cache/)
  for segment in norm:gmatch("[^/]+") do
    if segment:sub(1, 1) == "." then
      return true
    end
  end

  local ext = norm:match("%.([%w]+)$")
  if ext and BINARY_EXTENSIONS[ext:lower()] then
    return true
  end

  if privacy.is_sensitive_file(norm, blocked_patterns) then
    return true
  end

  for _, pat in ipairs(ignore_patterns or {}) do
    local ok, matched = pcall(string.find, norm, pat)
    if ok and matched then
      return true
    end
  end

  return false
end

---Check if file bytes look binary (contains NUL byte in first 512 bytes).
---@param content string
---@return boolean
local function is_binary_content(content)
  local sample = content:sub(1, 512)
  return sample:find("%z") ~= nil
end

---Extract lightweight symbol definitions (functions, classes, types) from source text.
---@param content string
---@param ext string
---@return { name: string, kind: string, sig: string }[], integer snake_count, integer camel_count
function M.extract_symbols_from_text(content, ext)
  local symbols = {}
  local snake = 0
  local camel = 0

  for _, raw_line in ipairs(util.split_lines(content)) do
    local line = util.trim(raw_line)
    if #line > 0 and #line <= 180 then
      local name, kind = nil, nil

      if ext == "lua" then
        name = line:match("^function%s+[%w_%.:]-([%w_]+)%s*%(")
          or line:match("^local%s+function%s+([%w_]+)%s*%(")
          or line:match("^M%.([%w_]+)%s*=%s*function%s*%(")
        if name then
          kind = "function"
        end
      elseif ext == "py" then
        name = line:match("^def%s+([%w_]+)%s*%(") or line:match("^async%s+def%s+([%w_]+)%s*%(")
        if name then
          kind = "function"
        else
          name = line:match("^class%s+([%w_]+)")
          if name then
            kind = "class"
          end
        end
      elseif ext == "js" or ext == "ts" or ext == "jsx" or ext == "tsx" then
        name = line:match("^export%s+async%s+function%s+([%w_$]+)%s*%(")
          or line:match("^export%s+function%s+([%w_$]+)%s*%(")
          or line:match("^async%s+function%s+([%w_$]+)%s*%(")
          or line:match("^function%s+([%w_$]+)%s*%(")
        if name then
          kind = "function"
        else
          name = line:match("^export%s+class%s+([%w_$]+)") or line:match("^class%s+([%w_$]+)")
          if name then
            kind = "class"
          end
        end
      elseif ext == "go" then
        name = line:match("^func%s+%b()%s*([%w_]+)%s*%(") or line:match("^func%s+([%w_]+)%s*%(")
        if name then
          kind = "function"
        else
          name = line:match("^type%s+([%w_]+)%s+struct")
          if name then
            kind = "struct"
          end
        end
      elseif ext == "rs" then
        name = line:match("^pub%s+async%s+fn%s+([%w_]+)")
          or line:match("^pub%s+fn%s+([%w_]+)")
          or line:match("^fn%s+([%w_]+)")
        if name then
          kind = "function"
        else
          name = line:match("^pub%s+struct%s+([%w_]+)") or line:match("^struct%s+([%w_]+)")
          if name then
            kind = "struct"
          end
        end
      end

      if name and kind then
        if name:find("_", 2, true) then
          snake = snake + 1
        elseif name:match("^[a-z]+[A-Z]") then
          camel = camel + 1
        end
        symbols[#symbols + 1] = {
          name = name,
          kind = kind,
          sig = line,
        }
        if #symbols >= 40 then
          break
        end
      end
    end
  end

  return symbols, snake, camel
end

---Detect project test framework and dependency hints from manifest files in `root`.
---@param root string
---@return string? test_framework, string[] deps
local function detect_project_metadata(root)
  local deps = {}
  local test_fw = nil

  local pkg_path = root .. "/package.json"
  local pkg_stat = uv.fs_stat(pkg_path)
  if pkg_stat and pkg_stat.size < 65536 then
    local fd = uv.fs_open(pkg_path, "r", 438)
    if fd then
      local raw = uv.fs_read(fd, pkg_stat.size, 0) or ""
      uv.fs_close(fd)
      local ok, decoded = pcall(vim.json.decode, raw)
      if ok and type(decoded) == "table" then
        for _, sec in ipairs({ "dependencies", "devDependencies" }) do
          if type(decoded[sec]) == "table" then
            for k, _ in pairs(decoded[sec]) do
              deps[#deps + 1] = k
              if k == "vitest" then
                test_fw = "vitest"
              elseif k == "jest" and not test_fw then
                test_fw = "jest"
              elseif k == "mocha" and not test_fw then
                test_fw = "mocha"
              end
            end
          end
        end
      end
    end
  end

  local py_path = root .. "/pyproject.toml"
  local py_stat = uv.fs_stat(py_path)
  if py_stat and py_stat.size < 65536 then
    local fd = uv.fs_open(py_path, "r", 438)
    if fd then
      local raw = uv.fs_read(fd, py_stat.size, 0) or ""
      uv.fs_close(fd)
      if raw:find("pytest", 1, true) then
        test_fw = test_fw or "pytest"
      end
    end
  end

  if uv.fs_stat(root .. "/Cargo.toml") then
    test_fw = test_fw or "cargo-test"
  elseif uv.fs_stat(root .. "/go.mod") then
    test_fw = test_fw or "go-test"
  elseif uv.fs_stat(root .. "/tests/run.lua") or uv.fs_stat(root .. "/lua") then
    test_fw = test_fw or "neovim-lua"
  end

  table.sort(deps)
  if #deps > 25 then
    local trimmed = {}
    for i = 1, 25 do
      trimmed[i] = deps[i]
    end
    deps = trimmed
  end

  return test_fw, deps
end

---Walk directory tree bounded by `max_files` without spawning external processes if git isn't used.
---@param root string
---@param max_files integer
---@param ignore_patterns string[]
---@param blocked_patterns string[]
---@return string[] rel_paths
local function collect_project_files(root, max_files, ignore_patterns, blocked_patterns)
  local results = {}
  local queue = { "" }

  while #queue > 0 and #results < max_files do
    local rel_dir = table.remove(queue, 1)
    local abs_dir = rel_dir == "" and root or (root .. "/" .. rel_dir)
    local handle = uv.fs_scandir(abs_dir)
    if handle then
      while #results < max_files do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then
          break
        end
        local child_rel = rel_dir == "" and name or (rel_dir .. "/" .. name)
        if not M.should_ignore(child_rel, ignore_patterns, blocked_patterns) then
          if ftype == "directory" then
            queue[#queue + 1] = child_rel
          elseif ftype == "file" then
            results[#results + 1] = child_rel
          end
        end
      end
    end
  end

  return results
end

---Index or incrementally refresh a single file inside `root`.
---@param root string
---@param rel_path string
---@param cfg table
---@return integer snake, integer camel
function M.index_single_file(root, rel_path, cfg)
  local idx_cfg = cfg.index or {}
  local priv_cfg = cfg.privacy or {}
  if M.should_ignore(rel_path, idx_cfg.ignore_patterns or {}, priv_cfg.blocked_file_patterns or {}) then
    M.state.files[rel_path] = nil
    return 0, 0
  end

  local abs = root .. "/" .. rel_path
  local stat = uv.fs_stat(abs)
  local max_bytes = idx_cfg.max_file_size_bytes or 65536
  if not stat or stat.type ~= "file" or stat.size <= 0 or stat.size > max_bytes then
    return 0, 0
  end

  local prev = M.state.files[rel_path]
  local mtime = stat.mtime and stat.mtime.sec or 0
  if prev and prev.mtime == mtime then
    return 0, 0
  end

  local fd = uv.fs_open(abs, "r", 438)
  if not fd then
    return 0, 0
  end
  local content = uv.fs_read(fd, stat.size, 0) or ""
  uv.fs_close(fd)

  if is_binary_content(content) then
    return 0, 0
  end

  local ext = (rel_path:match("%.([%w]+)$") or ""):lower()
  local symbols, snake, camel = M.extract_symbols_from_text(content, ext)
  local is_test = rel_path:lower():find("test", 1, true) ~= nil or rel_path:lower():find("spec", 1, true) ~= nil

  M.state.files[rel_path] = {
    mtime = mtime,
    symbols = symbols,
    is_test = is_test,
  }

  return snake, camel
end

---Build or incrementally update the project index in non-blocking batches.
---@param cfg table
---@param opts? { root?: string, sync?: boolean, on_done?: fun(summary: table) }
function M.build(cfg, opts)
  opts = opts or {}
  local root = opts.root or vim.fn.getcwd()
  local idx_cfg = cfg.index or {}
  local priv_cfg = cfg.privacy or {}

  local patterns = vim.deepcopy(idx_cfg.ignore_patterns or {})
  if idx_cfg.respect_gitignore ~= false then
    for _, gp in ipairs(load_gitignore_patterns(root)) do
      patterns[#patterns + 1] = gp
    end
  end

  local max_files = idx_cfg.max_files or 300
  local rel_files = collect_project_files(root, max_files, patterns, priv_cfg.blocked_file_patterns or {})
  local test_fw, deps = detect_project_metadata(root)

  M.state.root = root
  M.state.indexing = true
  M.state.conventions.test_framework = test_fw
  M.state.conventions.dependencies = deps

  local total_snake = 0
  local total_camel = 0

  local function finish()
    local count = 0
    for _ in pairs(M.state.files) do
      count = count + 1
    end
    M.state.file_count = count
    if total_camel > total_snake then
      M.state.conventions.naming = "camelCase"
    else
      M.state.conventions.naming = "snake_case"
    end
    M.state.indexing = false
    M.state.indexed = true
    M.state.last_indexed_ms = util.now_ms()
    if opts.on_done then
      opts.on_done(M.summary())
    end
  end

  if opts.sync then
    for _, rel in ipairs(rel_files) do
      local s, c = M.index_single_file(root, rel, cfg)
      total_snake = total_snake + s
      total_camel = total_camel + c
    end
    finish()
    return
  end

  -- Incremental slice processing (20 files per tick) so editing never stalls
  local cursor = 1
  local batch_size = 20
  local function step()
    local upper = math.min(#rel_files, cursor + batch_size - 1)
    for i = cursor, upper do
      local s, c = M.index_single_file(root, rel_files[i], cfg)
      total_snake = total_snake + s
      total_camel = total_camel + c
    end
    cursor = upper + 1
    if cursor <= #rel_files then
      vim.schedule(step)
    else
      finish()
    end
  end
  vim.schedule(step)
end

---Incrementally refresh a saved buffer path without re-walking the project.
---@param filepath string
---@param cfg table
function M.refresh_file(filepath, cfg)
  if not M.state.indexed or not M.state.root or filepath == "" then
    return
  end
  local root = M.state.root
  if filepath:sub(1, #root + 1) == root .. "/" then
    local rel = filepath:sub(#root + 2)
    M.index_single_file(root, rel, cfg)
  end
end

---Query relevant project symbols matching identifiers near the cursor, within `max_chars`.
---@param query_text string
---@param exclude_rel_path? string
---@param max_chars integer
---@return string
function M.query_relevant_symbols(query_text, exclude_rel_path, max_chars)
  if not M.state.indexed or max_chars <= 0 then
    return ""
  end

  local keywords = {}
  for word in (query_text or ""):gmatch("[%a_][%w_]*") do
    if #word >= 3 then
      keywords[word:lower()] = true
    end
  end

  local scored = {}
  for rel_path, info in pairs(M.state.files) do
    if rel_path ~= exclude_rel_path and not info.is_test then
      for _, sym in ipairs(info.symbols or {}) do
        local score = 0
        local lower_name = sym.name:lower()
        if keywords[lower_name] then
          score = score + 10
        else
          for kw, _ in pairs(keywords) do
            if lower_name:find(kw, 1, true) or kw:find(lower_name, 1, true) then
              score = score + 4
            end
          end
        end
        if score > 0 then
          scored[#scored + 1] = {
            score = score,
            line = string.format("%s: %s", rel_path, sym.sig),
          }
        end
      end
    end
  end

  table.sort(scored, function(a, b)
    return a.score > b.score
  end)

  local out = {}
  local used = 0
  for i = 1, math.min(#scored, 8) do
    local entry = scored[i].line
    if used + #entry + 1 > max_chars then
      break
    end
    out[#out + 1] = entry
    used = used + #entry + 1
  end

  return table.concat(out, "\n")
end

function M.summary()
  local total_symbols = 0
  for _, info in pairs(M.state.files) do
    total_symbols = total_symbols + #(info.symbols or {})
  end
  return {
    indexed = M.state.indexed,
    indexing = M.state.indexing,
    root = M.state.root,
    file_count = M.state.file_count,
    symbol_count = total_symbols,
    conventions = vim.deepcopy(M.state.conventions),
  }
end

function M.clear()
  M.state.indexed = false
  M.state.indexing = false
  M.state.file_count = 0
  M.state.files = {}
end

return M
