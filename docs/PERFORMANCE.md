# Performance & Weak-Hardware Guide

`assistit.nvim` is specifically engineered so old laptops without dedicated GPUs remain crisp, cool, and responsive.

---

## Honest Latency Expectations

`assistit.nvim` separates **plugin Lua overhead** from **local neural inference time**:

| Operation | Typical Plugin Overhead | Typical Local Inference Time (CPU-only Q4 0.5B–1.5B) |
| :--- | :--- | :--- |
| Active ghost-text prefix slice | **~0.02 ms** | **0 ms** (no HTTP request) |
| Exact / continuation LRU cache hit | **~0.05 ms** | **0 ms** (no HTTP request) |
| Layer A structural / offline completion | **~0.10–0.25 ms** | **0 ms** (no HTTP request) |
| Context extraction (`ultra_light` budget) | **~0.15–0.60 ms** | — |
| 0.5B Q4_K_M single-line FIM (4-core CPU) | ~0.5 ms | **~150–450 ms** (with warm KV cache) |
| 0.5B Q4_K_M multi-line FIM (old dual-core CPU) | ~0.5 ms | **~500–1,400 ms** |
| 1.5B Q4_K_M multi-line FIM (CPU-only) | ~0.6 ms | **~600–2,200 ms** |

Inspect real measured timings on your own machine at any time via `:AssistItStatus`.

---

## Hardware Profiles Comparison

Switch profiles in `setup({ profile = "..." })` or live via `:AssistItProfile <name>`:

| Setting | `ultra_light` (Weak CPU Laptops) | `balanced` (Modern Laptops) | `performance` (GPU / Apple Silicon / Desktops) |
| :--- | :--- | :--- | :--- |
| `completion.debounce_ms` | `240` ms | `160` ms | `100` ms |
| `completion.min_interval_ms` | `350` ms | `220` ms | `140` ms |
| `completion.max_tokens` | `96` | `192` | `384` |
| `completion.max_lines` | `12` | `25` | `48` |
| `completion.stream` | `false` | `true` | `true` |
| `context.max_prefix_chars` | `1200` (~300 tokens) | `2800` (~700 tokens) | `6000` (~1500 tokens) |
| `context.max_suffix_chars` | `400` (~100 tokens) | `1000` (~250 tokens) | `2200` (~550 tokens) |
| `index.enabled` | `false` | `true` (max 500 files) | `true` (max 2000 files) |
| `quality.intensity` | `"minimal"` | `"standard"` | `"deep"` |

---

## Practical Tips for Weak CPU-Only Computers

1. **Prefer `llama-server` (`llama.cpp`) with `-c 2048`:** `assistit.nvim` passes `cache_prompt = true` to `llama-server`, allowing `llama.cpp` to reuse the evaluated prompt prefix in its KV cache across edits instead of re-evaluating 300+ prompt tokens from scratch.
2. **Match thread count (`-t`) to physical CPU cores, not hyperthreads:** On a 2-core / 4-thread laptop CPU, `-t 2` or `-t 3` often avoids memory-bandwidth contention and keeps Neovim + OS UI snappy.
3. **Use `Q4_K_M` or `Q4_0` quantization:** CPU token generation is memory-bandwidth bound; 4-bit weights cut RAM traffic ~4x compared to FP16 with minimal coding accuracy loss on 0.5B–1.5B models.
4. **Enable streaming (`completion.stream = true`) if multi-line generation feels slow:** Streaming renders the first line of ghost text as soon as the first tokens arrive while remaining lines fill in below.
5. **Adaptive Scheduling works automatically:** When `:AssistItStatus` detects average HTTP inference > 1,000 ms, `metrics.adaptive_debounce_ms()` automatically widens the debounce interval to prevent request queue buildup on your CPU.
