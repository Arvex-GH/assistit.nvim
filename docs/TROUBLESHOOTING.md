# Troubleshooting Guide

Start by running Neovim's built-in health check and the plugin dashboard:

```vim
:checkhealth assistit
:AssistItStatus
```

---

## Common Issues & Solutions

### 1. Ghost text does not appear when typing
- **Check plugin state:** Ensure `:AssistItStatus` reports `State: ENABLED`.
- **Check buffer type:** Special buffers (`TelescopePrompt`, `neo-tree`, `terminal`, `nofile`, `readonly`, and `.env` / credential files) are intentionally skipped.
- **Check popup menu coexistence:** When a completion menu (`pumvisible()`, `nvim-cmp`, or `blink.cmp`) is open, `assistit.nvim` yields until the menu closes (`completion.respect_popup = true`).
- **Check backend connection:** If `:AssistItStatus` shows `Connection: DISCONNECTED`, verify your local server is running (`curl http://127.0.0.1:11434/api/tags` for Ollama or `curl http://127.0.0.1:8080/health` for `llama.cpp`). Note that after repeated connection failures, background auto-triggers enter polite exponential backoff; running `:AssistItComplete` resets backoff immediately.

### 2. Ollama says `model '...' not found`
Pull the configured model locally before starting Neovim:
```bash
ollama pull qwen2.5-coder:0.5b
```
Or update `model = "..."` in `require("assistit").setup({ ... })` to match one of the models listed in `ollama list`.

### 3. Model outputs prose or markdown fences instead of raw inline code
- Verify whether your model actually supports FIM tokens. Instruction/chat-only models (such as `llama3.2:1b` or `phi3`) do not have FIM tokens; set `completion = { fim_template = "prompt" }` if you renamed a custom Modelfile such that auto-detection picked a FIM template.
- For best inline ghost-text results, use a dedicated FIM coding model (`qwen2.5-coder:0.5b`, `qwen2.5-coder:1.5b`, `deepseek-coder:1.3b`, or `codegemma:2b`).

### 4. Custom `<Tab>` integration with `nvim-cmp` or `blink.cmp`
By default, `assistit.nvim` inspects `pumvisible()`, `cmp.visible()`, and `blink.cmp.is_visible()` and passes `<Tab>` straight through whenever a menu is visible.

If you prefer full manual control over `<Tab>` inside your own config, disable automatic keymaps and bind `<Plug>` targets directly:
```lua
require("assistit").setup({
  completion = {
    keymaps = { enabled = false },
  },
})

vim.keymap.set("i", "<C-y>", "<Plug>(assistit-accept)", { silent = true })
vim.keymap.set("i", "<M-w>", "<Plug>(assistit-accept-word)", { silent = true })
vim.keymap.set("i", "<M-l>", "<Plug>(assistit-accept-line)", { silent = true })
vim.keymap.set("i", "<C-]>", "<Plug>(assistit-next)", { silent = true })
```

### 5. Pressing `<Esc>` in Insert mode dismisses ghost text first instead of exiting Insert mode
By default (`esc_passthrough = false`), pressing `<Esc>` while a suggestion is visible dismisses the ghost text cleanly while keeping you in Insert mode; pressing `<Esc>` when no suggestion is visible exits Insert mode normally.
If you want `<Esc>` to **both** dismiss ghost text and immediately exit Insert mode in one keystroke:
```lua
require("assistit").setup({
  completion = {
    keymaps = {
      esc_passthrough = true,
    },
  },
})
```
