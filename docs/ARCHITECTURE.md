# Architecture Guide

> **Core Principle:** *The fastest useful AI is the one that does not need to think about everything.*

`assistit.nvim` is built as a **4-Layer Hybrid Intelligence System** in pure Lua for Neovim 0.10+. Rather than routing every trivial editing event through a heavy neural model, each request climbs the intelligence stack only as high as necessary.

```
Keystroke / Event
       │
       ▼
┌───────────────────────────────────────────────────────────────────┐
│ 0. Active Prefix-Continuation & O(1) LRU Cache  (~0.01–0.05 ms)   │
│    Slices active/cached completions in-memory as you keep typing  │
└──────┬────────────────────────────────────────────────────────────┘
       │ miss
       ▼
┌───────────────────────────────────────────────────────────────────┐
│ Layer A: Deterministic Intelligence             (~0.05–0.30 ms)   │
│  • Autopairs, doc/block scaffolds, identifier fallback            │
│  • Duplicate/unused imports, tautologies, security regex checks   │
└──────┬────────────────────────────────────────────────────────────┘
       │ needs deeper context
       ▼
┌───────────────────────────────────────────────────────────────────┐
│ Layer B: Language Intelligence (LSP + Tree-sitter)                │
│  • AST enclosing function/class scope & comment/string detection  │
│  • `vim.diagnostic` classification & native LSP code actions      │
│  • Respects `pumvisible()`, `nvim-cmp`, and `blink.cmp`           │
└──────┬────────────────────────────────────────────────────────────┘
       │ needs generative completion / synthesis
       ▼
┌───────────────────────────────────────────────────────────────────┐
│ Layer C: Tiny Local AI (0.5B–1.5B Quantized FIM Models)           │
│  • Async `vim.system` + `curl` over 127.0.0.1 (`stdin` payload)   │
│  • Model-specific FIM formatting (Qwen, DeepSeek, StarCoder, ...) │
│  • Streaming partial updates + `changedtick` stale rejection      │
└──────┬────────────────────────────────────────────────────────────┘
       │ explicit complex action (`:AssistItFix`, `:AssistItReview`, ...)
       ▼
┌───────────────────────────────────────────────────────────────────┐
│ Layer D: Optional Advanced Local Model                            │
│  • Routes explicit refactoring, testing, & repair diffs to a      │
│    larger local model when `advanced.enabled = true`              │
└───────────────────────────────────────────────────────────────────┘
```

---

## Module Boundaries

| Module | Responsibility |
| :--- | :--- |
| `plugin/assistit.lua` | Minimal startup entrypoint (<0.3 ms); version guard, highlights, command registration. |
| `lua/assistit/init.lua` | Public Lua API (`setup`, `enable`, `disable`, `statusline`, actions). |
| `lua/assistit/config.lua` | Hardware profiles (`ultra_light`, `balanced`, `performance`), schema validation, runtime profile switching. |
| `lua/assistit/privacy.lua` | Loopback endpoint enforcement, `.env`/key file blocking, multi-pattern secret redaction. |
| `lua/assistit/cache.lua` | Doubly-linked O(1) LRU cache with TTL plus same-line prefix-continuation slicer. |
| `lua/assistit/metrics.lua` | Monotonic latency EMA instrumentation, adaptive debounce scaling, offline exponential backoff. |
| `lua/assistit/deterministic/*` | Layer A: cursor-aware autopairs, structural micro-completions, static/security checks, safe transforms. |
| `lua/assistit/lsp/*` | Layer B: Tree-sitter AST scope/comment queries, popup menu detection, LSP code-action discovery. |
| `lua/assistit/context/*` | Strict character/token budget allocator, FIM prefix+suffix slicer, incremental `.gitignore`-aware project index. |
| `lua/assistit/providers/*` | Layer C/D: async `curl` transport, FIM template engine, Ollama, `llama.cpp`, and OpenAI-compatible adapters. |
| `lua/assistit/completion/*` | Ghost-text extmarks (`virt_text` + `virt_lines`), progressive word/line acceptance, non-intrusive keymaps. |
| `lua/assistit/diagnostics/*` | Diagnostic semantic classifier, multi-stage background quality hints, LSP-first -> AI repair workflow. |
| `lua/assistit/generation/*` | Explain, Refactor, Optimize, Doc, Test, Review, Generate + safe fenced-code extraction. |
| `lua/assistit/personalization/*` | Local-only statistical heuristics (preferred line length & debounce adaptation; never trains weights). |
| `lua/assistit/ui/*` | Native terminal floating previews, `vim.diff` unified diff proposals (`[Accept] [Reject] [Explain]`), status dashboard. |

---

## Stale-State & Cancellation Guarantees

CPU inference on older hardware can take anywhere from 150 ms to >1,500 ms. To ensure completions never corrupt or lag your editing flow:

1. **Zero main-loop blocking:** All HTTP requests spawn via `vim.system` (`libuv`) with payloads piped over `stdin`.
2. **Immediate subprocess termination:** Typing a non-matching character, moving the cursor with arrow keys, or leaving Insert mode calls `proc:kill("sigterm")` on any obsolete in-flight `curl` process.
3. **Monotonic sequence & `changedtick` verification:** Every request captures `(seq_id, bufnr, row, col, changedtick)`. Even if an HTTP response arrives 1 ms after an edit, `is_snapshot_fresh()` rejects it and increments `stale_rejected` in `:AssistItStatus`.
4. **0 ms Prefix-Continuation:** If `ghost.active` displays `result = compute(x)` and you keep typing `r`, `e`, `s`, `assistit.nvim` slices the active virtual text in-place (`ult = compute(x)`) in ~0.02 ms without cancelling or re-requesting inference.
