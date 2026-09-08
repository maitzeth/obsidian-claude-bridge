# SDD Design — Obsidian-Claude Bridge

## 1. File Structure

```
obsidian-claude-bridge/
├── install.sh              # Main installer (bash)
├── uninstall.sh            # Uninstaller (bash)
├── mcp_server.py           # MCP server implementation (Python 3 stdlib)
├── README.md               # User-facing documentation
├── openspec/
│   └── config.yaml         # SDD config (already exists)
└── .gitignore
```

---

## 2. Installer Architecture (`install.sh`)

### Phase 1: Preflight Checks
- `check_python()`: Verifies `python3` or `python` >= 3.8. Exits 1 if missing.
- `detect_claude_md()`: Resolves target `CLAUDE.md`.
  - If `--global` flag: `~/.claude/CLAUDE.md`
  - If `--claude-md PATH`: use PATH
  - Else interactive prompt with auto-detected options:
    - `~/.claude/CLAUDE.md` (if exists, mark as "exists")
    - `./CLAUDE.md` (if exists, mark as "exists")
    - Custom path input

### Phase 2: Vault Validation
- `validate_vault(PATH)`: Checks directory exists and contains at least one `.md` file (warn if none, don't fail).

### Phase 3: MCP Server Deployment
- `install_dir="$HOME/.config/obsidian-claude-bridge"`
- Create dir: `mkdir -p "$install_dir"`
- Write `mcp_server.py` from heredoc embedded in `install.sh`.
  - Rationale: Single-file installer, no dependency on repo structure after download.

### Phase 4: Claude Code Settings Mutation
- `settings_file="$HOME/.claude/settings.json"`
- Read existing JSON or initialize `{}`.
- Use Python one-liner for safe JSON mutation (avoids jq dependency):
  ```bash
  python3 -c "
  import json, sys
  data = json.load(open('$settings_file')) if os.path.exists('$settings_file') else {}
  data.setdefault('mcpServers', {})['obsidian-vault-mcp'] = {
    'command': '$python_cmd',
    'args': ['$install_dir/mcp_server.py', '--vault', '$vault_path']
  }
  json.dump(data, open('$settings_file', 'w'), indent=2)
  "
  ```

### Phase 5: CLAUDE.md Mutation
- Read existing `CLAUDE.md` or start with empty string.
- Check for markers with `grep`.
- If markers exist:
  - Use `sed` or `awk` to replace content between markers (portable approach: Python one-liner).
- If markers don't exist:
  - Append section at end of file with two newlines before.

### Phase 6: Summary
- Print:
  - Vault path configured
  - CLAUDE.md path modified
  - Settings file path
  - MCP server installed at
  - Next step: "Restart Claude Code or run `/mcp` to refresh tools."

---

## 3. Uninstaller Architecture (`uninstall.sh`)

### Phase 1: Detect Target
- Same auto-detect logic as installer (check `--claude-md`, `--global`, interactive).

### Phase 2: Remove CLAUDE.md Section
- Python one-liner for safe marker removal:
  ```python
  content = open(path).read()
  start = content.find('<!-- obsidian-bridge:v1')
  end = content.find('<!-- /obsidian-bridge:v1 -->')
  if start != -1 and end != -1:
      end += len('<!-- /obsidian-bridge:v1 -->')
      new_content = content[:start] + content[end:]
      # Clean up extra newlines
      open(path, 'w').write(new_content.strip() + '\n')
  ```

### Phase 3: Remove MCP Config (if `--all`)
- Python one-liner to pop `mcpServers.obsidian-vault-mcp` from settings JSON.
- `rm -rf "$HOME/.config/obsidian-claude-bridge"`

### Phase 4: Summary
- Print what was removed.

---

## 4. MCP Server Design (`mcp_server.py`)

### Entry Point
```python
if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault", required=True)
    args = parser.parse_args()
    server = VaultMCPServer(args.vault)
    server.run()
```

### Protocol Handler
- Reads JSON-RPC requests from stdin line-by-line.
- Supports `tools/list` and `tools/call` methods.
- Writes JSON-RPC responses to stdout.

### Tool Implementations

#### `search_vault`
```python
def search_vault(self, query: str, max_results: int = 10):
    results = []
    query_lower = query.lower()
    for root, dirs, files in os.walk(self.vault_path):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for f in files:
            if not f.endswith('.md'):
                continue
            full_path = os.path.join(root, f)
            rel_path = os.path.relpath(full_path, self.vault_path)
            title = f[:-3]
            # Filename match (priority 1)
            if query_lower in title.lower():
                preview = self._read_preview(full_path)
                results.append({"path": rel_path, "title": title, "preview": preview, "score": 2})
                continue
            # Content match (priority 2)
            try:
                with open(full_path, 'r', encoding='utf-8') as fh:
                    content = fh.read(5000)  # read enough for search
                    if query_lower in content.lower():
                        preview = content[:2000]
                        results.append({"path": rel_path, "title": title, "preview": preview, "score": 1})
            except Exception:
                continue
            if len(results) >= max_results * 2:
                break
    # Sort by score desc, take top max_results
    results.sort(key=lambda x: x["score"], reverse=True)
    return [{"path": r["path"], "title": r["title"], "preview": r["preview"]} 
            for r in results[:max_results]]
```

#### `read_note`
```python
def read_note(self, path: str):
    safe_path = os.path.normpath(os.path.join(self.vault_path, path))
    if not safe_path.startswith(os.path.normpath(self.vault_path)):
        raise ValueError("Path traversal attempt")
    if not os.path.exists(safe_path):
        raise FileNotFoundError(f"Note not found: {path}")
    with open(safe_path, 'r', encoding='utf-8') as f:
        return {"content": f.read(), "path": path}
```

#### `list_notes`
```python
def list_notes(self, directory: str = ""):
    target = os.path.normpath(os.path.join(self.vault_path, directory))
    if not target.startswith(os.path.normpath(self.vault_path)):
        raise ValueError("Path traversal attempt")
    entries = []
    for entry in os.listdir(target):
        if entry.startswith('.'):
            continue
        full = os.path.join(target, entry)
        rel = os.path.relpath(full, self.vault_path)
        entries.append({
            "name": entry,
            "path": rel,
            "is_directory": os.path.isdir(full)
        })
    return sorted(entries, key=lambda x: (not x["is_directory"], x["name"]))
```

---

## 5. Idempotency Algorithm

### CLAUDE.md Append/Replace
```
read file content
find START_MARKER in content
if found:
    find END_MARKER in content
    if found:
        new_content = content[0:start] + INJECTED_SECTION + content[end:]
    else:
        # malformed: replace from start to end of file + append end marker
        new_content = content[0:start] + INJECTED_SECTION
else:
    new_content = content + "\n\n" + INJECTED_SECTION
write new_content
```

### Settings JSON Mutation
```
read json
mcpServers = json.setdefault("mcpServers", {})
mcpServers["obsidian-vault-mcp"] = new_config
write json
```

---

## 6. Error Handling & Rollback

### Partial Install Rollback
If install fails mid-way, trap EXIT and:
- If CLAUDE.md was modified, restore from `.bak`.
- If settings JSON was modified, restore from `.bak`.
- Do NOT delete MCP server script (user may want to inspect).

### Backup Strategy
- Before mutating `CLAUDE.md`: `cp "$claude_md" "$claude_md.bak.$(date +%s)"`
- Before mutating settings: `cp "$settings" "$settings.bak.$(date +%s)"`

---

## 7. Portability

### Shell
- Use `/bin/sh` shebang for maximum portability, but bashisms for arrays/json are acceptable if `bash` is guaranteed. Given Claude Code targets developers, `#!/usr/bin/env bash` is fine.
- Path handling: quote all variables, use `"$HOME"` not `~`.

### Windows (Git Bash / WSL)
- `~` resolves correctly in Git Bash.
- Python path: try `python3`, fallback `python`, fallback `py`.
- Use `os.path` in Python (cross-platform).

---

## 8. Security

- Path traversal guard in all Python file operations.
- No execution of user-provided paths as shell commands.
- Settings JSON written via Python, not shell string interpolation.
