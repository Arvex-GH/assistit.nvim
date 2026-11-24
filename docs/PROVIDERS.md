# Local Model & Provider Setup Guide

`assistit.nvim` never downloads multi-gigabyte model weights behind your back and requires zero cloud accounts. Connect any locally installed inference runtime on loopback (`127.0.0.1`).

---

## Recommended Small Coding Models (0.5B – 1.5B Range)

For weak laptops without dedicated GPUs, **4-bit quantized (`Q4_K_M`) FIM-capable coding models** offer the best balance of RAM footprint (~400 MB – 1.1 GB) and single-core/dual-core CPU responsiveness:

| Model Family | Parameters | Approx. Q4 RAM | Native FIM Support | `fim_template` (auto-detected) | Notes |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Qwen2.5-Coder 0.5B** | 0.49B | ~400 MB | Yes (`<\|fim_prefix\|>`) | `"qwen"` | Best default for older CPU-only laptops. |
| **Qwen2.5-Coder 1.5B** | 1.54B | ~1.0 GB | Yes (`<\|fim_prefix\|>`) | `"qwen"` | Noticeably stronger multi-line & function generation on 8 GB+ RAM laptops. |
| **DeepSeek-Coder 1.3B** | 1.3B | ~850 MB | Yes (`<｜fim▁begin｜>`) | `"deepseek"` | Solid FIM completion quality across Python, JS/TS, Go, C, and Lua. |
| **CodeGemma 2B** | 2.0B | ~1.4 GB | Yes (`<fim_prefix>`) | `"starcoder"` | Strong FIM & docstring synthesis; slightly heavier on older CPUs. |
| **StarCoder2 3B** | 3.0B | ~1.9 GB | Yes (`<fim_prefix>`) | `"starcoder"` | Recommended for `balanced` / `performance` profiles. |
| **Llama 3.2 1B / SmolLM2** | 1.0B–1.7B | ~750 MB | Instruct / Prompt (`smollm2` starcoder FIM) | `"prompt"` / `"starcoder"` | General instruct models without FIM tokens automatically use the `"prompt"` fallback template. |

> **Important:** Not every local model supports Fill-In-the-Middle (FIM) special tokens. When `completion.fim_template = "auto"` (default), `assistit.nvim` selects the exact token format for Qwen, DeepSeek, StarCoder/CodeGemma/Granite, CodeLlama, or Codestral, and falls back to a compact cursor-continuation prompt (`"prompt"`) for general chat/instruct models.

---

## 1. llama.cpp (`llama-server`) — Lowest Overhead on Weak Hardware

`llama.cpp` has minimal daemon memory overhead and supports **prompt KV-cache reuse (`cache_prompt = true`)** plus a dedicated `/infill` endpoint.

### Start `llama-server`
```bash
llama-server \
  -m ~/models/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf \
  --host 127.0.0.1 \
  --port 8080 \
  -c 2048 \
  -t 4
```

### Neovim Configuration
```lua
require("assistit").setup({
  profile = "ultra_light",
  provider = "llamacpp",
  endpoint = "http://127.0.0.1:8080",
  model = "qwen2.5-coder-0.5b-instruct-q4_k_m.gguf",
})
```
*Note:* If an older `llama-server` build or model returns HTTP 404/501 on `/infill`, `assistit.nvim` automatically falls back to `/completion` with formatted FIM tokens.

---

## 2. Ollama — Easiest Model Management

### Pull a Tiny Model
```bash
ollama pull qwen2.5-coder:0.5b
# Or for 8GB+ RAM machines:
ollama pull qwen2.5-coder:1.5b
```

### Neovim Configuration
```lua
require("assistit").setup({
  profile = "ultra_light",
  provider = "ollama",
  endpoint = "http://127.0.0.1:11434",
  model = "qwen2.5-coder:0.5b",
})
```

---

## 3. OpenAI-Compatible Local Endpoints (LM Studio, vLLM, mlx_lm, LocalAI)

Connect any local server exposing `/v1/completions` and/or `/v1/chat/completions`. If a server only implements `/v1/chat/completions` (returning 404/405 on `/v1/completions`), `assistit.nvim` automatically falls back to `/v1/chat/completions`.

```lua
require("assistit").setup({
  profile = "balanced",
  provider = "openai_compat",
  endpoint = "http://127.0.0.1:1234",
  model = "qwen2.5-coder-1.5b-instruct",
  -- Optional env var name if your local proxy requires a bearer token:
  api_key_env = "LOCAL_LLM_API_KEY",
})
```

---

## 4. Layer D: Dual-Model Setup (Tiny Inline + Larger Action Model)

On workstations or Apple Silicon / GPU laptops, you can keep instant ghost-text completions on a 0.5B model while routing explicit `:AssistItFix`, `:AssistItRefactor`, `:AssistItReview`, and `:AssistItTest` commands to a 7B+ local model:

```lua
require("assistit").setup({
  profile = "performance",
  provider = "ollama",
  model = "qwen2.5-coder:0.5b",
  advanced = {
    enabled = true,
    provider = "ollama",
    model = "qwen2.5-coder:7b",
    timeout_ms = 30000,
    max_tokens = 1024,
  },
})
```

---

## 5. Offline Deterministic-Only Mode (`provider = "none"`)

When traveling on battery or working on machines with no model installed, set `provider = "none"`. Layer A deterministic micro-completions, autopairs, static import/conditional/security checks, and `:AssistItCleanup` run locally with zero network processes.
