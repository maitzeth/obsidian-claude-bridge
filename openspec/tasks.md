# SDD Tasks — Obsidian-Claude Bridge

## Implementation Tasks

### Core Files
- [x] **T1**: Create `mcp_server.py` — MCP server over stdio with `search_vault`, `read_note`, `list_notes` tools. Python stdlib only. Includes path traversal guards and vault scoping.
- [x] **T2**: Create `install.sh` — Interactive installer with flags (`--vault`, `--claude-md`, `--global`, `--yes`). Handles Python check, vault validation, MCP deployment, settings mutation, and `CLAUDE.md` idempotent append/replace. Includes backup and rollback on failure.
- [x] **T3**: Create `uninstall.sh` — Removes `CLAUDE.md` section between markers. Supports `--all` to remove MCP config and server script. Includes auto-detect logic for target `CLAUDE.md`.
- [x] **T4**: Create `README.md` — User-facing docs: what it does, prerequisites, install steps, uninstall steps, troubleshooting, Windows notes.
- [x] **T5**: Create `.gitignore` — Standard ignores for Python and shell project.

### QA & Polish
- [x] **T6**: Syntax check `install.sh` and `uninstall.sh` (`bash -n`).
- [ ] **T7**: Test `mcp_server.py` manually with sample vault (search, read, list).
- [ ] **T8**: Test `install.sh` idempotency (run twice, verify no duplication in CLAUDE.md or settings).
- [ ] **T9**: Test `uninstall.sh` with and without `--all`.
- [ ] **T10**: Test on macOS/Linux (Git Bash verification done on Windows).

### Review Guard
- Estimated changed lines: ~550 across 6 files. Within review budget.
- Manual testing pending (requires Python runtime and sample vault).
