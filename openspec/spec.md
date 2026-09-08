# SDD Spec — Obsidian-Claude Bridge

## 1. MCP Server Contract

### Server: `obsidian-vault-mcp`

Protocol: MCP (Model Context Protocol) over stdio.

### Tools

#### `search_vault`
- **Description**: Search Obsidian vault notes by keyword in filename or content.
- **Input**:
  - `query` (string, required): Keyword or phrase to search.
  - `max_results` (number, optional, default: 10): Max notes to return.
- **Output**: Array of note objects:
  - `path` (string): Relative path from vault root.
  - `title` (string): Filename without `.md`.
  - `preview` (string): First 2000 chars of content.
- **Behavior**:
  - Case-insensitive search in filename and content.
  - Skip non-`.md` files.
  - Skip hidden directories (`.` prefix).
  - If `max_results` exceeded, return top matches (first by filename match, then by content match).

#### `read_note`
- **Description**: Read the full content of a single note.
- **Input**:
  - `path` (string, required): Relative path from vault root (e.g., `Domain/Architecture.md`).
- **Output**:
  - `content` (string): Full markdown content.
  - `path` (string): Confirmed path.
- **Errors**:
  - `file_not_found`: If path does not exist or is outside vault directory (traversal guard).

#### `list_notes`
- **Description**: List notes in a directory within the vault.
- **Input**:
  - `directory` (string, optional, default: `""`): Relative directory path. Empty string = vault root.
- **Output**: Array of objects:
  - `name` (string): Filename.
  - `path` (string): Relative path.
  - `is_directory` (boolean): Whether it's a subfolder.

### Security
- Path traversal guard: Reject any `path` containing `..` or starting with `/`.
- Scope lock: Server only accesses files under the configured vault root.

---

## 2. CLAUDE.md Section Contract

### Marker Format

```markdown
<!-- obsidian-bridge:v1 — do not edit between markers — use: ./uninstall.sh -->
## Obsidian Domain Context

Before modifying any code, writing tests, or making architectural decisions, you MUST consult the Obsidian vault for domain context. Use the `obsidian-vault-mcp` tools:

1. **Search** (`search_vault`): Look for notes related to the current task using keywords from filenames, module names, and business domain terms.
2. **Read** (`read_note`): Read relevant notes fully before proceeding.
3. **List** (`list_notes`): If unsure where domain knowledge lives, browse the vault structure.

The vault contains authoritative business rules, architecture decisions, API contracts, and domain terminology. Treat it as the source of truth for this project's domain layer.

Vault root: {VAULT_PATH}
<!-- /obsidian-bridge:v1 -->
```

### Rules
- **R-S1**: Markers must be exact HTML comments (`<!-- obsidian-bridge:v1 -->` and `<!-- /obsidian-bridge:v1 -->`).
- **R-S2**: Content between markers is owned by the installer; manual edits may be overwritten on re-install.
- **R-S3**: The uninstaller removes only the content between markers plus the markers themselves.

---

## 3. Installer Contract (`install.sh`)

### Arguments
- `--vault PATH` or `-v PATH`: Path to Obsidian vault.
- `--claude-md PATH` or `-c PATH`: Path to target `CLAUDE.md`. Default: auto-detect.
- `--global`: Force global `~/.claude/CLAUDE.md`.
- `--yes` or `-y`: Skip confirmation prompts.

### Interactive Prompts (if no flags provided)
1. "Path to your Obsidian vault?" (validate directory exists).
2. "Which CLAUDE.md to modify?"
   - Option 1: Global (`~/.claude/CLAUDE.md`)
   - Option 2: Project (current directory `./CLAUDE.md`)
   - Option 3: Custom path
3. "Install MCP server and configure Claude Code? [y/N]"

### Steps
1. Validate Python 3.8+ is available (`python3 --version` or `python --version`).
2. Detect or create target `CLAUDE.md` directory.
3. Copy `mcp_server.py` to `~/.config/obsidian-claude-bridge/mcp_server.py` (or `~/.obsidian-claude-bridge/`).
4. Register MCP in Claude Code settings:
   - Read existing settings JSON (create if absent).
   - Add/update `mcpServers.obsidian-vault-mcp` entry with:
     - `command`: `python3` (or `python`)
     - `args`: `["/absolute/path/to/mcp_server.py", "--vault", "/path/to/vault"]`
5. Append or replace the Obsidian Bridge section in target `CLAUDE.md`.
6. Print summary of changes and next steps.

### Idempotency
- If `obsidian-vault-mcp` already exists in settings, update args (don't duplicate).
- If markers already exist in `CLAUDE.md`, replace content between them.
- If `mcp_server.py` already exists at target, overwrite with latest version.

---

## 4. Uninstaller Contract (`uninstall.sh`)

### Arguments
- `--claude-md PATH` or `-c PATH`: Target `CLAUDE.md`. Default: auto-detect (same logic as installer).
- `--all`: Also remove MCP server script and settings entry.

### Steps
1. Detect target `CLAUDE.md`.
2. Remove section between `<!-- obsidian-bridge:v1 -->` and `<!-- /obsidian-bridge:v1 -->`.
3. If `--all`:
   - Remove `mcpServers.obsidian-vault-mcp` from Claude Code settings.
   - Remove `~/.config/obsidian-claude-bridge/` directory.
4. Print what was removed.

---

## 5. Configuration Files

### Claude Code Settings Path
- Primary: `~/.claude/settings.json`
- Structure:
```json
{
  "mcpServers": {
    "obsidian-vault-mcp": {
      "command": "python3",
      "args": ["/home/user/.config/obsidian-claude-bridge/mcp_server.py", "--vault", "/path/to/vault"]
    }
  }
}
```

### MCP Server Install Path
- `~/.config/obsidian-claude-bridge/mcp_server.py`

---

## 6. Error Handling

| Error | Behavior |
|---|---|
| Python not found | Exit with code 1, print "Python 3.8+ is required." |
| Vault path invalid | Exit with code 1, print "Vault path does not exist or is not a directory." |
| CLAUDE.md not writable | Exit with code 1, print "Cannot write to CLAUDE.md at {path}." |
| Settings JSON malformed | Backup and overwrite, print warning. |
| Cancelled by user (Ctrl-C) | Trap SIGINT, print "Installation cancelled. No changes made." (rollback if partial). |
