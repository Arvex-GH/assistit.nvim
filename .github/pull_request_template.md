## Summary

- What does this change do?
- Which Hybrid Intelligence Layer (`A: Deterministic`, `B: LSP/Tree-sitter`, `C: Tiny Local AI`, `D: Advanced`) does it touch?

## Checklist

- [ ] Preserves normal Neovim key behavior when no suggestion is visible or a popup is open
- [ ] Zero blocking calls on the main editor loop
- [ ] Local-only by default; no telemetry or unredacted secret exposure
- [ ] Headless Neovim test suite passes (`nvim --headless -u NONE -l tests/run.lua`)
- [ ] Documentation updated (`README.md` / `doc/assistit.txt` / `docs/*.md`)
