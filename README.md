# assistit.nvim

**Ultra-lightweight, local-first hybrid AI coding companion for Neovim 0.10+.**

> *"The fastest useful AI is the one that does not need to think about everything."*

`assistit.nvim` feels like a quiet, intelligent extension of Neovim itself — not a cloud chatbot bolted onto your editor. Designed to run comfortably on **weak, older laptops without dedicated GPUs**, it combines sub-millisecond deterministic Lua intelligence, built-in LSP & Tree-sitter awareness, and tiny quantized local coding models (0.5B–1.5B) over `127.0.0.1`.

No cloud API keys. No subscriptions. No accounts. No telemetry. Zero external Lua plugin dependencies.

---

## Terminal Experience

```text
  1 │ local function active_usernames(users)
  2 │   local names = {}
  3 │   for ▌user in ipairs(users) do                <-- subtle inline ghost text
  · │     if user.is_active then                     <-- multi-line virt_lines
  · │       names[#names + 1] = user.name
  · │     end
  · │   end
  · │   return names
  4 │ end
    └─ <Tab> Accept   <M-w> Next Word   <M-l> Next Line   <Esc> Dismiss   <C-]> Next
```

When inspecting diagnostics (`:AssistItFix`) or refactoring (`:AssistItRefactor`), changes are **never applied silently** — every proposal opens a lightweight terminal diff window labeled by provenance:

```text
╭─────────────────── AssistIt Proposed Repair ───────────────────╮
│ [AI Hypothesis — Unverified, Review Before Applying]           │
│ ⚠ Confirmed Issue [undefined]: Undefined global `input`.       │
│ AI Repair Hypothesis: Initialize fallback table when nil.      │
│ ────────────────────────────────────────────────────────────── │
│ @@ -1,2 +1,2 @@                                                │
│ -local result = input                                          │
│ +local result = input or {}                                    │
│  return result                                                 │
│ ────────────────────────────────────────────────────────────── │
│ [a / <CR>] Accept    [r / q / <Esc>] Reject    [e] Explain     │
╰────────────────────────────────────────────────────────────────╯
```

---

## Why `assistit.nvim` Is Different

Most AI plugins send entire buffers to massive models on every pause. On CPU-only laptops, that burns battery, saturates RAM, and lags behind your typing.

`assistit.nvim` uses a **4-Layer Hybrid Intelligence System**:

1. **0 ms Prefix-Continuation & LRU Cache:** Keep typing characters that match an active or cached suggestion and `assistit.nvim` slices the remaining ghost text in-memory (~0.02 ms) with zero network calls.
2. **Layer A — Deterministic Intelligence (<0.3 ms, zero model required):** Cursor-aware bracket/quote autopairs, structural block & docstring scaffolds, offline buffer-identifier continuations, duplicate/unused import checks, tautological condition checks, security pattern detection (`eval`, shell concatenation, hardcoded secrets), and `:AssistItCleanup`.
3. **Layer B — Language Intelligence (LSP + Tree-sitter):** Resolves the exact language at your cursor (including embedded Markdown code fences, Vue/Svelte/HTML `<script>`/`<style>` blocks, Tree-sitter language injections, and unsaved-buffer shebang/syntax inference), extracts enclosing function/class AST scope, prioritizes **confirmed LSP code actions** before asking an LLM to guess a fix, and yields `<Tab>` automatically whenever `pumvisible()`, `nvim-cmp`, or `blink.cmp` is open.
4. **Layer C & Optional Layer D — Tiny Local AI (0.5B–1.5B FIM) + Optional Larger Local Model:** Connects asynchronously via `vim.system` + `curl` to **Ollama**, **`llama.cpp` (`llama-server`)**, or **OpenAI-compatible local servers**, using model-accurate Fill-In-the-Middle (FIM) tokens (`qwen`, `deepseek`, `starcoder`, `codellama`, `codestral`) or a prompt fallback. Users with stronger hardware can optionally route deep actions (`:AssistItFix`, `:AssistItRefactor`, `:AssistItReview`, `:AssistItTest`) to a larger local model (`advanced`).

---

## What Works Without a Model vs. With a Local Model

| Capability | Offline (`provider = "none"`) | With Tiny Local Model (0.5B–1.5B) | With Optional Layer D (3B–14B+) |
| :--- | :---: | :---: | :---: |
| Cursor-aware bracket/quote autopairs | Yes | Yes | Yes |
| Structural doc/block micro-completions & identifier fallback | Yes | Yes | Yes |
| Duplicate/unused import, tautology, & security static checks | Yes | Yes | Yes |
| Safe deterministic `:AssistItCleanup` & LSP formatting | Yes | Yes | Yes |
| Native LSP quickfix discovery in `:AssistItFix` | Yes | Yes | Yes |
| Predictive FIM ghost-text expressions, lines, & full functions | — | **Yes** | Yes |
| Comment-to-code & `:AssistItGenerate` | — | **Yes** | Yes |
| AI error explanations & diff-previewed `:AssistItFix` repairs | — | **Yes** | Stronger |
| `:AssistItRefactor`, `:AssistItOptimize`, `:AssistItDoc`, `:AssistItTest` | Stubs / Static | **Yes** | Stronger |

---

## Requirements & Expected Hardware

- **Neovim:** `>= 0.10.0`
- **Transport:** `curl` in `PATH` (only required when connecting to an HTTP local model server; zero Lua rocks or Node/Python runtime dependencies)
- **Hardware expectations (honest numbers):**
  - **Old CPU-only laptop (4 GB – 8 GB RAM, no dGPU):** Run `qwen2.5-coder:0.5b` (Q4_K_M, ~400 MB RAM) with `profile = "ultra_light"`. Plugin Lua overhead is **< 1 ms**; local CPU generation typically takes **~150–450 ms** on 4-core CPUs and **~500–1,400 ms** on older dual-core CPUs.
  - **Standard laptop (8 GB – 16 GB RAM):** Run `qwen2.5-coder:1.5b` or `deepseek-coder:1.3b` (~0.9–1.1 GB RAM) with `profile = "balanced"`.
  - **Apple Silicon / GPU workstation (16 GB+ RAM):** Use `profile = "performance"` and optionally configure `advanced` with a 7B+ local model.

---

## One-Click Setup (Linux & Windows CMD)

Clone the repository and run the interactive one-click installer — it checks/installs Neovim `>= 0.10` and Ollama, lets you **choose 1 of 10 curated local coding models** (or `0` for zero-download offline mode), pulls your chosen model, and configures Neovim safely without overwriting your existing `init.lua`:

**Linux (`setup.sh`):**
```bash
git clone https://github.com/Arvex-GH/assistit.nvim.git
cd assistit.nvim
./setup.sh
```

**Windows Command Prompt / Explorer (`setup.bat`):**
```bat
git clone https://github.com/Arvex-GH/assistit.nvim.git
cd assistit.nvim
setup.bat
```
*(Or simply double-click `setup.bat` in Windows File Explorer.)*

### The 10 Built-In Local Model Choices

| # | Ollama Model Tag | Download | RAM | Auto Profile | Best For |
| :-: | :--- | :---: | :---: | :---: | :--- |
| `1` | `qwen2.5-coder:0.5b` | ~400 MB | ~1 GB | `ultra_light` | Old CPU-only laptops (4–8 GB RAM) |
| `2` | `deepseek-coder:1.3b` | ~780 MB | ~2 GB | `ultra_light` | Fast multi-language FIM on CPU laptops |
| `3` | `yi-coder:1.5b` | ~870 MB | ~2 GB | `balanced` | Compact 128K-context all-rounder |
| `4` | `qwen2.5-coder:1.5b` | ~990 MB | ~2 GB | `balanced` | Everyday laptop sweet spot (8 GB+ RAM) |
| `5` | `codegemma:2b` | ~1.6 GB | ~3 GB | `balanced` | Google fast FIM completion specialist |
| `6` | `starcoder2:3b` | ~1.7 GB | ~4 GB | `balanced` | BigCode 600+ languages FIM model |
| `7` | `qwen2.5-coder:3b` | ~1.9 GB | ~4 GB | `balanced` | Strong mid-size coder (8–16 GB RAM) |
| `8` | `deepseek-coder:6.7b` | ~3.8 GB | ~6 GB | `performance` | Desktop / GPU high-accuracy coder |
| `9` | `codellama:7b` | ~3.8 GB | ~6 GB | `performance` | Meta CodeLlama 7B FIM classic |
| `10` | `qwen2.5-coder:7b` | ~4.7 GB | ~8 GB | `performance` | Workstation / GPU flagship coder |
| `0` | *Offline Mode (`none`)* | 0 MB | 0 MB | `ultra_light` | Layer A deterministic + LSP only |

You can switch between installed models anytime inside Neovim with `:aim 4` or `:aim qwen2.5-coder:3b`!

---

## Manual Plugin Manager Installation

### `lazy.nvim`

```lua
{
  "Arvex-GH/assistit.nvim",
  event = { "InsertEnter", "CmdlineEnter" },
  opts = {
    profile = "ultra_light", -- "ultra_light" | "balanced" | "performance"
    provider = "ollama",     -- "ollama" | "llamacpp" | "openai_compat" | "none"
    model = "qwen2.5-coder:0.5b",
  },
}
```

### `mini.deps`

```lua
MiniDeps.add("Arvex-GH/assistit.nvim")
require("assistit").setup({
  profile = "ultra_light",
  provider = "ollama",
  model = "qwen2.5-coder:0.5b",
})
```

### Native Neovim Packages (`packpath`)

```bash
git clone https://github.com/Arvex-GH/assistit.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/assistit.nvim
```

---

## Connecting a Local Model (2 Minutes)

### Option A: Ollama
```bash
ollama pull qwen2.5-coder:0.5b
```
```lua
require("assistit").setup({
  profile = "ultra_light",
  provider = "ollama",
  endpoint = "http://127.0.0.1:11434",
  model = "qwen2.5-coder:0.5b",
})
```

### Option B: `llama.cpp` (`llama-server`) — Minimal RAM Overhead
```bash
llama-server -m ~/models/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf --host 127.0.0.1 --port 8080 -c 2048 -t 4
```
```lua
require("assistit").setup({
  profile = "ultra_light",
  provider = "llamacpp",
  endpoint = "http://127.0.0.1:8080",
  model = "qwen2.5-coder-0.5b-instruct-q4_k_m.gguf",
})
```

### Option C: OpenAI-Compatible Local Server (LM Studio, vLLM, mlx_lm, LocalAI)
```lua
require("assistit").setup({
  profile = "balanced",
  provider = "openai_compat",
  endpoint = "http://127.0.0.1:1234",
  model = "qwen2.5-coder-1.5b-instruct",
})
```

Verify connectivity inside Neovim with `:checkhealth assistit` or `:AssistItStatus`.

---

## Full Configuration Reference

```lua
require("assistit").setup({
  enabled = true,
  profile = "ultra_light", -- "ultra_light" | "balanced" | "performance"

  provider = "ollama",     -- "ollama" | "llamacpp" | "openai_compat" | "none"
  model = "qwen2.5-coder:0.5b",
  endpoint = "http://127.0.0.1:11434",

  -- Optional Layer D larger local model for :AssistItFix / Refactor / Review / Test
  advanced = {
    enabled = false,
    provider = nil, -- inherits primary provider when nil
    model = nil,    -- e.g. "qwen2.5-coder:7b"
    endpoint = nil,
    timeout_ms = 30000,
    max_tokens = 1024,
  },

  completion = {
    enabled = true,
    auto_trigger = true,
    debounce_ms = 240,
    min_interval_ms = 350,
    cooldown_ms = 200,
    max_lines = 12,
    max_tokens = 96,
    fim_template = "auto", -- "auto" | "qwen" | "deepseek" | "starcoder" | "codellama" | "codestral" | "prompt"
    stream = false,
    progressive_accept = true,
    deterministic_fallback = true,
    respect_popup = true,  -- never steals <Tab> from pumvisible / nvim-cmp / blink.cmp
    keymaps = {
      enabled = true,
      accept = "<Tab>",
      accept_word = "<M-w>",
      accept_word_alt = "<M-Tab>",
      accept_line = "<M-l>",
      dismiss = "<Esc>",
      esc_passthrough = false,
      next_suggestion = "<C-]>",
      complete_block = "<C-g><C-b>",
    },
  },

  deterministic = {
    enabled = true,
    autopairs = "auto",            -- auto-disables if nvim-autopairs / mini.pairs is loaded
    auto_cleanup_whitespace = false,
    micro_completions = true,
  },

  diagnostics = {
    enabled = true,
    ai_suggestions = true,
    automatic_fixes = false,       -- AI fixes are NEVER applied automatically
  },

  quality = {
    enabled = true,
    intensity = "minimal",         -- "minimal" | "standard" | "deep"
    on_type = true,
    on_pause = false,
    on_save = true,
  },

  personalization = {
    enabled = true,
    local_only = true,             -- statistical heuristics only; never trains neural weights
  },

  privacy = {
    local_only = true,             -- blocks non-loopback endpoints unless allow_remote = true
    allow_remote = false,
    redact_secrets = true,         -- scrubs API tokens, PEM keys, JWTs, & URI passwords
  },
})
```

### Optional Statusline Component (`lualine` / native)
```lua
-- Returns e.g. "assistit ● qwen2.5-coder 210ms" or "assistit:det"
require("assistit").statusline()
```

---

## Commands & Controls

All commands use crisp `:Ai*` names — and when `short_commands = true` (default), you can type them in **pure lowercase** right at the `:` prompt (`:aip`, `:aim`, `:aif`, `:aie`, etc.) without holding Shift! Full `:AssistIt*` names remain available as backwards-compatible aliases.

| Short Command | Lowercase | Full Alias | Description |
| :--- | :--- | :--- | :--- |
| `:Ai [sub]` | `:ai` | `:AssistIt` | Unified command dispatcher (`:ai s`, `:ai p u`, `:ai m 4`, `:ai f`) |
| `:Ais` | `:ais` | `:AssistItStatus` | Open live connection, privacy, cache, & measured latency dashboard |
| `:Aip <u\|b\|p>` | `:aip` | `:AssistItProfile` | Switch hardware profile (`ultra_light`/`u`, `balanced`/`b`, `performance`/`p`) |
| `:Aim <1-10\|tag>` | `:aim` | `:AssistItModel` | Switch active local model (`1`–`10`, Ollama tag, or `none`) |
| `:Ail` | `:ail` | `:AssistItLatency` | Show honest latency & cache hit summary |
| `:[range]Aif` | `:aif` | `:AssistItFix` | Inspect diagnostic & propose reviewable diff fix (LSP -> AI) |
| `:[range]Aie` | `:aie` | `:AssistItExplain` | Concisely explain selected range or enclosing function |
| `:[range]Air` | `:air` | `:AssistItRefactor` | Propose refactored code in interactive diff preview |
| `:[range]Aio` | `:aio` | `:AssistItOptimize` | Propose performance & memory-allocation improvements |
| `:[range]Aid` | `:aid` | `:AssistItDoc` | Generate idiomatic docstrings/type annotations with diff preview |
| `:[range]Ait` | `:ait` | `:AssistItTest` | Generate unit tests tailored to detected project conventions |
| `:[range]Aiv` | `:aiv` | `:AssistItReview` | Run hybrid deterministic static + local AI code & security review |
| `:Aig [prompt]` | `:aig` | `:AssistItGenerate` | Generate code block from prompt or current-line comment |
| `:Aic` | `:aic` | `:AssistItCleanup` | Deterministically remove duplicate imports & trailing whitespace |
| `:Aii` | `:aii` | `:AssistItIndex` | Build or refresh incremental `.gitignore`-aware project symbol index |
| `:Aicp` / `:Aicb` | `:aicp` / `:aicb` | `:AssistItComplete[Block]` | Trigger inline ghost-text or multi-line block completion |
| `:Aia` / `:Aiaw` / `:Aial` | `:aia` / `:aiaw` / `:aial` | `:AssistItAccept[Word\|Line]` | Accept full suggestion, next word, or next line |
| `:Aix` | `:aix` | `:AssistItDismiss` | Dismiss active ghost-text suggestion or preview window |
| `:Aion` / `:Aioff` / `:Aitg` | `:aion` / `:aioff` / `:aitg` | `:AssistItEnable\|Disable\|Toggle` | Enable, disable, or toggle `assistit.nvim` |
| `:Aicc` / `:Airl` | `:aicc` / `:airl` | `:AssistItClearCache` / `ResetLearning` | Clear LRU cache or reset local personalization stats |

---

## Privacy Guarantees

- **100% local by default:** Non-loopback URLs are rejected unless you explicitly set `privacy = { local_only = false, allow_remote = true }`.
- **Zero telemetry:** No usage pings, analytics, or external network calls.
- **Secret protection:** `.env*`, `*.pem`, `*.key`, `id_rsa*`, and `credentials.json` files are excluded from context extraction and indexing; API keys, JWTs, PEM blocks, and URI passwords in source files are redacted to `<REDACTED_SECRET>`.
- **Safe process execution:** Payloads are streamed to `curl` via `stdin`, never CLI arguments (`ps aux`), and model output is never executed as shell commands or applied without review.
- **Transparent local adaptation:** Personalization stores only aggregate counters and 8-char hashes in `stdpath("data")/assistit/personalization.json` (`0600` permissions) — never raw source code.

---

## Known Limitations

- **Tiny models (0.5B–1.5B) are great at local pattern continuation and FIM, not deep multi-file theorem proving:** Keep expectations realistic. Tiny models excel at boilerplate, loops, struct/table mappings, docstrings, and localized bug fixes, while complex architectural reasoning benefits from connecting an optional Layer D 7B+ model.
- **CPU latency depends on hardware memory bandwidth:** Cache hits and deterministic Layer A run in `< 0.3 ms`, whereas fresh neural token generation on old dual-core CPUs takes hundreds of milliseconds to ~1.5 seconds.
- **Deterministic static checks complement, rather than replace, full language servers:** Layer A catches duplicate/unused imports, tautologies, and common dangerous calls quickly, while deep typechecking belongs to your attached LSP server (`lua_ls`, `pyright`, `ts_ls`, `gopls`, `rust-analyzer`).

---

## Testing

Run the full automated unit + async headless Neovim integration suite (39 specs covering config, privacy redaction, LRU & prefix-continuation caching, Ollama/`llama.cpp`/OpenAI-compat streaming & fallbacks, Tree-sitter context budgets, incremental indexing, progressive acceptance, stale-response rejection, popup keymap safety, and diff repairs):

```bash
nvim --headless -u NONE -l tests/run.lua
```

---

## Documentation

- [Architecture Guide](docs/ARCHITECTURE.md)
- [Local Providers & FIM Model Matrix](docs/PROVIDERS.md)
- [Privacy & Security Model](docs/PRIVACY.md)
- [Performance & Weak-Hardware Tuning](docs/PERFORMANCE.md)
- [Troubleshooting Guide](docs/TROUBLESHOOTING.md)
- [Contributing Guide](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)
- Vimdoc: `:help assistit`

---

## License

[MIT](LICENSE) © 2026 Arvex-GH
