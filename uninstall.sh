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
PROJECT_DIR=""
USE_GLOBAL=false
REMOVE_ALL=false
PYTHON_CMD=""
REMOVED_SECTIONS=0

# --- Helpers ---
print_help() {
    cat <<HELP
Obsidian-Claude Bridge Uninstaller v${VERSION}

Usage: ./uninstall.sh [OPTIONS]

Options:
  -c, --claude-md PATH  Path to target CLAUDE.md (default: ask)
  -p, --project DIR     Project directory: cleans its CLAUDE.md and CLAUDE.local.md
  -g, --global          Use global CLAUDE.md (~/.claude/CLAUDE.md)
  -a, --all             Also remove the MCP server script and its registration
                        (user, local and project scopes)
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
    [[ -n "$CLAUDE_MD_TARGET" || -n "$PROJECT_DIR" ]] && return
    if [[ "$USE_GLOBAL" == true ]]; then
        CLAUDE_MD_TARGET="${HOME}/.claude/CLAUDE.md"
        return
    fi

    echo ""
    log_info "Which installation should I remove?"
    echo "  1) Global:  ~/.claude/CLAUDE.md"
    echo "  2) Project: <project>/CLAUDE.md and CLAUDE.local.md"
    echo "  3) Custom CLAUDE.md path"
    echo ""
    read -rp "Choice [1-3, default: 1]: " choice
    case "${choice:-1}" in
        2)
            read -rp "Project directory [${PWD}]: " PROJECT_DIR
            PROJECT_DIR="${PROJECT_DIR:-$PWD}"
            ;;
        3) read -rp "Enter full path to CLAUDE.md: " CLAUDE_MD_TARGET ;;
        *) CLAUDE_MD_TARGET="${HOME}/.claude/CLAUDE.md" ;;
    esac
    if [[ -z "$CLAUDE_MD_TARGET" && -z "$PROJECT_DIR" ]]; then
        log_err "CLAUDE.md path or project directory is required."
        exit 1
    fi
}

remove_section() {
    # $1 = markdown file. Silently skips missing files.
    local file="$1"
    [[ -f "$file" ]] || return 0
    grep -q "$MARKER_START" "$file" || return 0
    log_info "Removing Obsidian Bridge section from ${file}..."
    backup_file "$file"
    "$PYTHON_CMD" - "$file" "$MARKER_START" "$MARKER_END" <<'PYEOF'
import sys

path, marker_start, marker_end = sys.argv[1:4]

with open(path, "r", encoding="utf-8") as f:
    content = f.read()

start_idx = content.find(marker_start)
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
PYEOF
    if [[ ! -s "$file" ]]; then
        rm -f "$file"
        log_ok "$(basename "$file") contained only the bridge section; file removed (backup kept)"
    else
        log_ok "$(basename "$file") cleaned"
    fi
    REMOVED_SECTIONS=$((REMOVED_SECTIONS + 1))
}

remove_mcp_entry() {
    # $1 = JSON config file, $2 = scopes to clean (comma list of user,local,project), $3 = project dir
    local file="$1" scopes="$2" project_dir="${3:-}"
    [[ -f "$file" ]] || return 0
    "$PYTHON_CMD" - "$file" "$SERVER_NAME" "$scopes" "$project_dir" <<'PYEOF'
import json, os, shutil, sys, time

path, server_name, scopes, project_dir = sys.argv[1:5]
scopes = set(scopes.split(","))
with open(path, "r", encoding="utf-8") as f:
    raw = f.read()
try:
    data = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError:
    print(f"[WARN] {path} is not valid JSON; left untouched.")
    sys.exit(0)

containers = []
if isinstance(data, dict):
    if "user" in scopes or "project" in scopes:
        label = "project" if os.path.basename(path) == ".mcp.json" else "user"
        containers.append((label, data.get("mcpServers")))
    if "local" in scopes and project_dir:
        containers.append(("local", data.get("projects", {}).get(project_dir, {}).get("mcpServers")))

hits = [(label, srv) for label, srv in containers if isinstance(srv, dict) and server_name in srv]
if not hits:
    print(f"No '{server_name}' entry in {path}.")
    sys.exit(0)

shutil.copy2(path, f"{path}.bak.{int(time.time())}")
for label, srv in hits:
    del srv[server_name]
    print(f"Removed '{server_name}' ({label} scope) from {path}.")
servers = data.get("mcpServers", {})
if not servers and os.path.basename(path) == ".mcp.json":
    # Project file that we created and is now empty: drop it entirely.
    os.remove(path)
    print(f"Removed empty {path}.")
else:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
PYEOF
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--claude-md) require_arg "$1" $#; CLAUDE_MD_TARGET="$2"; shift 2 ;;
        -p|--project)   require_arg "$1" $#; PROJECT_DIR="$2"; shift 2 ;;
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

if [[ -n "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(expand_tilde "$PROJECT_DIR")"
    [[ -d "$PROJECT_DIR" ]] || { log_err "Project directory does not exist: $PROJECT_DIR"; exit 1; }
    PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
    TARGETS=("${PROJECT_DIR}/CLAUDE.md" "${PROJECT_DIR}/CLAUDE.local.md")
else
    CLAUDE_MD_TARGET="$(expand_tilde "$CLAUDE_MD_TARGET")"
    CLAUDE_MD_TARGET="$("$PYTHON_CMD" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$CLAUDE_MD_TARGET")"
    PROJECT_DIR="$(dirname "$CLAUDE_MD_TARGET")"
    TARGETS=("$CLAUDE_MD_TARGET")
fi
IS_GLOBAL_TARGET=false
[[ "$CLAUDE_MD_TARGET" == "${HOME}/.claude/CLAUDE.md" ]] && IS_GLOBAL_TARGET=true

# --- Remove CLAUDE.md sections ---
for target in "${TARGETS[@]}"; do
    remove_section "$target"
done
if [[ "$REMOVED_SECTIONS" -eq 0 ]]; then
    log_warn "No Obsidian Bridge section found in: ${TARGETS[*]}"
fi

# --- Remove MCP registration and server (if --all) ---
if [[ "$REMOVE_ALL" == true ]]; then
    log_info "Removing MCP registration..."
    if [[ "$IS_GLOBAL_TARGET" == true ]]; then
        remove_mcp_entry "$USER_MCP_FILE" "user"
    else
        remove_mcp_entry "$USER_MCP_FILE" "local" "$PROJECT_DIR"
        remove_mcp_entry "${PROJECT_DIR}/.mcp.json" "project"
    fi

    if [[ -d "$INSTALL_DIR" ]]; then
        if grep -rqs "\"${SERVER_NAME}\"" "$USER_MCP_FILE" 2>/dev/null; then
            log_warn "Other installations still reference ${SERVER_NAME}; keeping ${INSTALL_DIR}"
        else
            rm -rf "$INSTALL_DIR"
            log_ok "MCP server removed from ${INSTALL_DIR}"
        fi
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
