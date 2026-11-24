# Changelog

All notable changes to `assistit.nvim` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-23

### Added
- **4-Layer Hybrid Intelligence System**:
  - **Layer A (Deterministic Intelligence):** Cursor-aware autopairs, instant doc/block scaffolds, offline identifier continuations, duplicate & unused import detection, suspicious conditional detection, security pattern warnings, and `:AssistItCleanup`.
  - **Layer B (Language Intelligence):** Built-in `vim.lsp` code-action & diagnostic integration, `vim.treesitter` AST enclosing scope & comment/string detection with regex fallback, and safe coexistence with `pumvisible()`, `nvim-cmp`, and `blink.cmp`.
  - **Layer C (Tiny Local AI):** Asynchronous FIM inline ghost-text completion (`virt_text` + `virt_lines`), streaming NDJSON/SSE support, model-aware FIM templates (`qwen`, `deepseek`, `starcoder`, `codellama`, `codestral`, `prompt`), and providers for `ollama`, `llamacpp` (`llama-server`), and `openai_compat`.
  - **Layer D (Optional Advanced Model):** Configurable secondary local model routing for deeper actions (`:AssistItFix`, `:AssistItRefactor`, `:AssistItReview`, `:AssistItTest`).
- **Progressive Acceptance & 0ms Prefix-Continuation:** Full `<Tab>`, next-word `<M-w>` / `<M-Tab>`, next-line `<M-l>`, `<Esc>` dismiss, `<C-]>` alternative cycling, suffix overlap deduplication, and in-place 0ms ghost-text slicing while typing.
- **Hardware Profiles & Adaptive Scheduler:** `ultra_light`, `balanced`, `performance`, and `custom_profiles`, plus real-time latency instrumentation, adaptive debounce scaling, and offline exponential backoff.
- **Reviewable Diff UI:** Floating `vim.diff` proposal windows (`[Accept] [Reject] [Explain]`) with clear provenance labels (`[Confirmed LSP Diagnostic]`, `[Deterministic Static Check]`, `[AI Hypothesis — Unverified]`).
- **Privacy & Local Personalization:** Strict loopback enforcement, sensitive file blocking (`.env`, private keys, credentials), multi-pattern secret redaction, `stdin` payload isolation, and local-only statistical preference adaptation (`0600` JSON, zero raw code persisted).
- **Documentation & Headless Test Suite:** Full `:help assistit` Vimdoc, `:checkhealth assistit`, deep-dive guides in `docs/`, GitHub Actions CI, and 39 automated headless Neovim unit & integration tests.
