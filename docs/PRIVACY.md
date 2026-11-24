# Privacy & Security Guarantees

Privacy is a foundational architectural constraint of `assistit.nvim`, not an afterthought.

---

## Default Local-Only Guarantees

1. **Zero Telemetry & Analytics:** `assistit.nvim` contains no telemetry, crash reporting, usage pings, or update checks.
2. **Loopback Enforcement:** By default (`privacy.local_only = true`, `privacy.allow_remote = false`), both `config.validate()` and `transport.request()` block any endpoint that is not a loopback address (`127.0.0.1`, `localhost`, `[::1]`, or local Unix socket).
3. **Explicit Opt-In for Remote Endpoints:** Connecting a LAN workstation or remote server requires setting both `privacy = { local_only = false, allow_remote = true }` explicitly. `:AssistItStatus` and `:checkhealth assistit` prominently display `OPT-IN REMOTE ENDPOINT` whenever a non-loopback URL is active.
4. **Process Argument Isolation:** HTTP JSON bodies are piped to `curl` over standard input (`--data-binary @-`) rather than command-line flags, preventing source code snippets from leaking into OS process tables (`ps aux` / `/proc/<pid>/cmdline`).

---

## Secret Redaction & Sensitive File Blocking

Even when communicating with a local model on `127.0.0.1`, `assistit.nvim` prevents accidental credential ingestion into model KV caches or logs:

### Blocked Sensitive Files (`privacy.blocked_file_patterns`)
Context extraction, AI repair, code generation, and project indexing automatically skip files matching:
- `.env`, `.env.*` (`.env.local`, `.env.production`, etc.)
- `*.pem`, `*.key`, `*.p12`, `*.pfx`
- `id_rsa*`, `id_ed25519*`, `id_ecdsa*`, and paths inside `/.ssh/`, `/.gnupg/`, `/.aws/credentials`
- `credentials.json`, `secret*.yml`, `secret*.yaml`, `.netrc`, `.git-credentials`

### Automatic Prompt Redaction (`privacy.redact_secrets = true`)
Before assembling prompts, `privacy.redact_secrets()` scrubs:
- PEM private key blocks (`-----BEGIN ... PRIVATE KEY-----`)
- Known token formats (`sk-...`, `sk-proj-...`, `sk-ant-...`, `ghp_...`, `github_pat_...`, `glpat-...`, `xox[baprs]-...`, `sk_live_...`, `AKIA...` AWS keys)
- JWT tokens (`eyJ...`) and `Authorization: Bearer ...` values
- Embedded connection URI passwords (`postgres://user:pass@host`, `redis://:pass@host`)
- High-signal quoted credential assignments (`password = "..."`, `api_key = "..."`, `client_secret = "..."`)

---

## Untrusted Model Output & Edit Safety

- **Never executes generated commands:** Model output is treated strictly as untrusted text. `assistit.nvim` never passes model output to `os.execute`, `vim.fn.system`, or `loadstring`.
- **Never silently overwrites code:** Ghost text requires explicit user acceptance (`<Tab>`, `<M-w>`, `<M-l>`). `:AssistItFix`, `:AssistItRefactor`, `:AssistItOptimize`, `:AssistItDoc`, and `:AssistItGenerate` open an interactive unified diff preview (`[Accept] [Reject] [Explain]`) and apply edits as a single undoable Neovim change (`u`).
- **Provenance labeling:** Every preview clearly distinguishes `[Confirmed LSP Diagnostic]`, `[Deterministic Static Check]`, and `[AI Hypothesis — Unverified, Review Before Applying]`.

---

## Local Personalization Storage (`personalization.json`)

When `personalization.enabled = true`, `assistit.nvim` stores lightweight statistical counters in:
`vim.fn.stdpath("data") .. "/assistit/personalization.json"` (permissions `0600`, owner read/write only).

**What is stored:**
- Aggregate counts (`total_shown`, `total_accepted_full`, `total_accepted_partial`, `total_dismissed`)
- Per-filetype acceptance ratios and average accepted line counts
- Bounded 8-character non-reversible FNV-1a hashes of accepted snippet prefixes

**What is NEVER stored:**
- Raw source code, file paths, or buffer contents
- Any cloud/account identifier

Disable at any time with `personalization = { enabled = false }`, or wipe all stored statistics immediately with `:AssistItResetLearning`.
