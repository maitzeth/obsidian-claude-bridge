#!/usr/bin/env bash
set -euo pipefail

# Obsidian-Claude Bridge Uninstaller

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.0.0"
MARKER_START="<!-- obsidian-bridge:v1"
MARKER_END="<!-- /obsidian-bridge:v1 -->"
INSTALL_DIR="${HOME}/.config/obsidian-claude-bridge"
SETTINGS_FILE="${HOME}/.claude/settings.json"

# --- Defaults ---
CLAUDE_MD_TARGET=""
USE_GLOBAL=false
REMOVE_ALL=false

# --- Helpers ---
print_help() {
    cat <<EOF
Obsidian-Claude Bridge Uninstaller v${VERSION}

Usage: ./uninstall.sh [OPTIONS]

Options:
  -c, --claude-md PATH  Path to target CLAUDE.md (default: auto-detect)
  -g, --global          Force global CLAUDE.md (~/.claude/CLAUDE.md)
  -a, --all             Also remove MCP server script and settings entry
  -h, --help            Show this help message
EOF
}

log_info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
log_ok()   { echo -e "\033[1;32m[OK]\033[0m   $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_err()  { echo -e "\033[1;31m[ERR]\033[0m  $1" >&2; }

detect_target() {
    if [[ -n "$CLAUDE_MD_TARGET" ]]; then
        return
    fi
    if [[ "$USE_GLOBAL" == true ]]; then
        CLAUDE_MD_TARGET="${HOME}/.claude/CLAUDE.md"
        return
    fi

    echo ""
    log_info "Which CLAUDE.md should I clean?"
    echo "  1) Global: ~/.claude/CLAUDE.md"
    echo "  2) Project: ${PWD}/CLAUDE.md"
    echo "  3) Custom path"
    echo ""
    read -rp "Choice [1-3, default: 1]: " choice
    case "${choice:-1}" in
        2)
            CLAUDE_MD_TARGET="${PWD}/CLAUDE.md"
            ;;
        3)
            read -rp "Enter full path to CLAUDE.md: " custom_path
            CLAUDE_MD_TARGET="$custom_path"
            ;;
        *)
            CLAUDE_MD_TARGET="${HOME}/.claude/CLAUDE.md"
            ;;
    esac
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--claude-md)
            CLAUDE_MD_TARGET="$2"
            shift 2
            ;;
        -g|--global)
            USE_GLOBAL=true
            shift
            ;;
        -a|--all)
            REMOVE_ALL=true
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            log_err "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

detect_target
CLAUDE_MD_TARGET="${CLAUDE_MD_TARGET/#\~/$HOME}"

if [[ ! -f "$CLAUDE_MD_TARGET" ]]; then
    log_warn "CLAUDE.md not found at ${CLAUDE_MD_TARGET}"
    if [[ "$REMOVE_ALL" != true ]]; then
        exit 0
    fi
fi

# --- Remove CLAUDE.md section ---
if [[ -f "$CLAUDE_MD_TARGET" ]]; then
    log_info "Removing Obsidian Bridge section from ${CLAUDE_MD_TARGET}..."

    python3 - "$CLAUDE_MD_TARGET" "$MARKER_START" "$MARKER_END" <<'PYEOF'
import sys, os

path = sys.argv[1]
marker_start = sys.argv[2]
marker_end = sys.argv[3]

with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

start_idx = content.find(marker_start)
if start_idx == -1:
    print("No Obsidian Bridge section found.")
    sys.exit(0)

end_idx = content.find(marker_end)
if end_idx == -1:
    print("Malformed section: start marker found but no end marker. Cleaning from start to end of file.")
    new_content = content[:start_idx]
else:
    end_idx += len(marker_end)
    new_content = content[:start_idx] + content[end_idx:]

# Clean up extra whitespace/newlines
new_content = new_content.rstrip() + '\n'

with open(path, 'w', encoding='utf-8') as f:
    f.write(new_content)

print("Section removed.")
PYEOF

    log_ok "CLAUDE.md cleaned"
fi

# --- Remove MCP config and server (if --all) ---
if [[ "$REMOVE_ALL" == true ]]; then
    log_info "Removing MCP configuration..."

    if command -v python3 &>/dev/null; then
        python3 - "$SETTINGS_FILE" <<'PYEOF'
import json, sys, os

path = sys.argv[1]
if not os.path.exists(path):
    print("Settings file not found.")
    sys.exit(0)

with open(path, 'r', encoding='utf-8') as f:
    try:
        data = json.load(f)
    except json.JSONDecodeError:
        print("Settings file is malformed.")
        sys.exit(0)

if 'mcpServers' in data and 'obsidian-vault-mcp' in data['mcpServers']:
    del data['mcpServers']['obsidian-vault-mcp']
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    print("MCP entry removed from settings.")
else:
    print("No MCP entry found in settings.")
PYEOF
    else
        log_warn "python3 not found; cannot clean settings.json automatically."
    fi

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
    echo "Removed: CLAUDE.md section, MCP settings, and server script."
else
    echo "Removed: CLAUDE.md section only."
    echo "MCP server and settings remain intact."
    echo "Use './uninstall.sh --all' to remove everything."
fi
