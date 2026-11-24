# Contributing to assistit.nvim

Thank you for helping build a lightweight, local-first coding companion for Neovim!

---

## Core Engineering Guidelines

1. **Ask whether an LLM is actually needed:** Before adding a prompt, check whether Layer A (deterministic Lua heuristics) or Layer B (`vim.lsp` / `vim.treesitter`) can solve the problem faster and more reliably.
2. **Zero main-loop stalls:** Never run synchronous shell commands (`vim.fn.system`, `io.popen`) or full-project file scans on typing events. Use `vim.system` and `vim.uv` asynchronously.
3. **Zero external runtime plugin dependencies:** `assistit.nvim` must work out of the box on stock Neovim >= 0.10 + `curl`. Integrations with `nvim-cmp`, `blink.cmp`, and `nvim-treesitter` must always degrade gracefully when absent.
4. **Never break normal Vim muscle memory:** Keymaps must pass through cleanly whenever no ghost text is active or a completion popup is open.
5. **Privacy & edit safety:** Never add telemetry, never expose unredacted secrets, and never silently overwrite buffer lines with AI-generated code.

---

## Running the Automated Test Suite

The test suite runs in headless Neovim (>= 0.10) with zero external Lua rocks required. `tests/run.lua` automatically boots a local Python 3 loopback mock server simulating Ollama, `llama.cpp`, and OpenAI-compatible streaming/non-streaming endpoints.

```bash
# Run all test suites
nvim --headless -u NONE -l tests/run.lua

# Run a single spec file by substring filter
ASSISTIT_SPEC=07_completion nvim --headless -u NONE -l tests/run.lua
```

Verify Vimdoc help tags:
```bash
nvim --headless -u NONE -c "helptags doc" -c "qa!" && rm -f doc/tags
```

---

## Adding a New Local Provider

Implement a provider table with `complete(ctx, opts, callbacks)`, `generate(prompt_spec, opts, callbacks)`, `check_health(opts, on_done)`, and optional `warmup(opts, on_done)`, then register it:

```lua
require("assistit.providers").register("my_local_engine", my_provider)
```

See `lua/assistit/providers/llamacpp.lua` and `lua/assistit/providers/ollama.lua` for reference implementations, and add test coverage in `tests/spec/04_fim_providers_spec.lua`.
