#!/usr/bin/env bash
# Obsidian-Claude Bridge Uninstaller
# Compatible with bash 3.2+ (stock macOS), Linux, WSL and Git Bash.
set -euo pipefail

VERSION="1.1.0"
SERVER_NAME="obsidian-vault-mcp"
MARKER_START="<!-- obsidian-bridge:v1"
MARKER_END="<!-- /obsidian-bridge:v1 -->"
INSTALL_DIR="${HOME}/.config/obsidian-claude-bridge"
USER_MCP_FILE="${HOME}/.claude.json"

# --- Defaults ---
CLAUDE_MD_TARGET=""
USE_GLOBAL=false
REMOVE_ALL=false
PYTHON_CMD=""

# --- Helpers ---
print_help() {
    cat <<HELP
Obsidian-Claude Bridge Uninstaller v${VERSION}

Usage: ./uninstall.sh [OPTIONS]

Options:
  -c, --claude-md PATH  Path to target CLAUDE.md (default: ask)
  -g, --global          Use global CLAUDE.md (~/.claude/CLAUDE.md)
  -a, --all             Also remove the MCP server script and its registration
                        (from ~/.claude.json and from .mcp.json next to CLAUDE.md)
  -h, --help            Show this help message
HELP
}

log_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$1"; }
log_ok()   { printf '\033[1;32m[OK]\033[0m   %s\n' "$1"; }
log_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
log_err()  { printf '\033[1;31m[ERR]\033[0m  %s\n' "$1" >&2; }

expand_tilde() { printf '%s' "${1/#\~/$HOME}"; }

check_python() {
    local candidate
    for candidate in python3 python py; do
        if command -v "$candidate" >/dev/null 2>&1 &&
           "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
            PYTHON_CMD="$candidate"
            return
        fi
    done
    log_err "Python 3.8+ is required but was not found (tried: python3, python, py)."
    exit 1
}

require_arg() {
    if [[ "$2" -lt 2 ]]; then
        log_err "Option $1 requires a value."
        exit 1
    fi
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local bak="${file}.bak.$(date +%s)"
        cp "$file" "$bak"
        log_info "Backup: ${bak}"
    fi
}

detect_target() {
    [[ -n "$CLAUDE_MD_TARGET" ]] && return
    if [[ "$USE_GLOBAL" == true ]]; then
        CLAUDE_MD_TARGET="${HOME}/.claude/CLAUDE.md"
        return
    fi

    echo ""
    log_info "Which CLAUDE.md should I clean?"
    echo "  1) Global:  ~/.claude/CLAUDE.md"
    echo "  2) Project: ${PWD}/CLAUDE.md"
    echo "  3) Custom path"
    echo ""
    read -rp "Choice [1-3, default: 1]: " choice
    case "${choice:-1}" in
        2) CLAUDE_MD_TARGET="${PWD}/CLAUDE.md" ;;
        3) read -rp "Enter full path to CLAUDE.md: " CLAUDE_MD_TARGET ;;
        *) CLAUDE_MD_TARGET="${HOME}/.claude/CLAUDE.md" ;;
    esac
    if [[ -z "$CLAUDE_MD_TARGET" ]]; then
        log_err "CLAUDE.md path is required."
        exit 1
    fi
}

remove_mcp_entry() {
    # $1 = JSON config file
    local file="$1"
    [[ -f "$file" ]] || return 0
    "$PYTHON_CMD" - "$file" "$SERVER_NAME" <<'PYEOF'
import json, os, shutil, sys, time

path, server_name = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as f:
    raw = f.read()
try:
    data = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError:
    print(f"[WARN] {path} is not valid JSON; left untouched.")
    sys.exit(0)

servers = data.get("mcpServers") if isinstance(data, dict) else None
if not isinstance(servers, dict) or server_name not in servers:
    print(f"No '{server_name}' entry in {path}.")
    sys.exit(0)

shutil.copy2(path, f"{path}.bak.{int(time.time())}")
del servers[server_name]
if not servers and os.path.basename(path) == ".mcp.json":
    # Project file that we created and is now empty: drop it entirely.
    os.remove(path)
    print(f"Removed empty {path}.")
else:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"Removed '{server_name}' from {path}.")
PYEOF
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--claude-md) require_arg "$1" $#; CLAUDE_MD_TARGET="$2"; shift 2 ;;
        -g|--global)    USE_GLOBAL=true; shift ;;
        -a|--all)       REMOVE_ALL=true; shift ;;
        -h|--help)      print_help; exit 0 ;;
        *)
            log_err "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

check_python
detect_target
CLAUDE_MD_TARGET="$(expand_tilde "$CLAUDE_MD_TARGET")"
CLAUDE_MD_TARGET="$("$PYTHON_CMD" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$CLAUDE_MD_TARGET")"

# --- Remove CLAUDE.md section ---
if [[ -f "$CLAUDE_MD_TARGET" ]]; then
    log_info "Removing Obsidian Bridge section from ${CLAUDE_MD_TARGET}..."
    backup_file "$CLAUDE_MD_TARGET"

    "$PYTHON_CMD" - "$CLAUDE_MD_TARGET" "$MARKER_START" "$MARKER_END" <<'PYEOF'
import sys

path, marker_start, marker_end = sys.argv[1:4]

with open(path, "r", encoding="utf-8") as f:
    content = f.read()

start_idx = content.find(marker_start)
if start_idx == -1:
    print("No Obsidian Bridge section found.")
    sys.exit(0)

end_idx = content.find(marker_end, start_idx)
if end_idx == -1:
    print("Malformed section (no end marker); removing from start marker to end of file.")
    new_content = content[:start_idx]
else:
    new_content = content[:start_idx] + content[end_idx + len(marker_end):]

# Collapse the blank lines we introduced around the section.
new_content = new_content.replace("\n\n\n", "\n\n").rstrip()
new_content = new_content + "\n" if new_content else ""

with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)
print("Section removed.")
PYEOF
    log_ok "CLAUDE.md cleaned"
else
    log_warn "CLAUDE.md not found at ${CLAUDE_MD_TARGET}; nothing to clean there."
fi

# --- Remove MCP registration and server (if --all) ---
if [[ "$REMOVE_ALL" == true ]]; then
    log_info "Removing MCP registration..."
    remove_mcp_entry "$USER_MCP_FILE"
    remove_mcp_entry "$(dirname "$CLAUDE_MD_TARGET")/.mcp.json"

    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        log_ok "MCP server removed from ${INSTALL_DIR}"
    fi
fi

# --- Summary ---
echo ""
echo "========================================"
echo "  Obsidian-Claude Bridge v${VERSION}"
echo "  Uninstall complete!"
echo "========================================"
echo ""
if [[ "$REMOVE_ALL" == true ]]; then
    echo "Removed: CLAUDE.md section, MCP registration, and server script."
else
    echo "Removed: CLAUDE.md section only."
    echo "MCP server and registration remain intact."
    echo "Use './uninstall.sh --all' to remove everything."
fi
echo "Restart Claude Code for the change to take effect."
