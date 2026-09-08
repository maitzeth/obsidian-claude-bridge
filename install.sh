#!/usr/bin/env bash
set -euo pipefail

# Obsidian-Claude Bridge Installer
# Connects Claude Code with your Obsidian vault for automatic domain context.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.0.0"
MARKER_START="<!-- obsidian-bridge:v1 — do not edit between markers — use: ./uninstall.sh -->"
MARKER_END="<!-- /obsidian-bridge:v1 -->"
INSTALL_DIR="${HOME}/.config/obsidian-claude-bridge"
SETTINGS_FILE="${HOME}/.claude/settings.json"

# --- Defaults ---
VAULT_PATH=""
CLAUDE_MD_TARGET=""
USE_GLOBAL=false
SKIP_CONFIRM=false
PYTHON_CMD=""

# --- Helpers ---
print_help() {
    cat <<EOF
Obsidian-Claude Bridge Installer v${VERSION}

Usage: ./install.sh [OPTIONS]

Options:
  -v, --vault PATH      Path to your Obsidian vault directory
  -c, --claude-md PATH  Path to target CLAUDE.md (default: auto-detect)
  -g, --global          Force global CLAUDE.md (~/.claude/CLAUDE.md)
  -y, --yes             Skip confirmation prompts
  -h, --help            Show this help message

Examples:
  ./install.sh --vault ~/Documents/ObsidianVault
  ./install.sh --vault ~/Vault --global --yes
  ./install.sh --vault ~/Vault --claude-md ./CLAUDE.md
EOF
}

log_info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
log_ok()   { echo -e "\033[1;32m[OK]\033[0m   $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_err()  { echo -e "\033[1;31m[ERR]\033[0m  $1" >&2; }

check_python() {
    if command -v python3 &>/dev/null; then
        PYTHON_CMD="python3"
    elif command -v python &>/dev/null; then
        PYTHON_CMD="python"
    elif command -v py &>/dev/null; then
        PYTHON_CMD="py"
    else
        log_err "Python 3.8+ is required but not found."
        log_err "Please install Python and try again."
        exit 1
    fi

    local pyver
    pyver=$("$PYTHON_CMD" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    log_info "Found Python ${pyver} (${PYTHON_CMD})"

    if ! "$PYTHON_CMD" -c "import sys; exit(0 if sys.version_info >= (3,8) else 1)"; then
        log_err "Python 3.8+ is required. Found ${pyver}"
        exit 1
    fi
}

detect_claude_md_options() {
    local options=()
    if [[ -f "${HOME}/.claude/CLAUDE.md" ]]; then
        options+=("global" "Global: ~/.claude/CLAUDE.md (exists)")
    else
        options+=("global" "Global: ~/.claude/CLAUDE.md (will be created)")
    fi
    if [[ -f "${PWD}/CLAUDE.md" ]]; then
        options+=("project" "Project: ${PWD}/CLAUDE.md (exists)")
    else
        options+=("project" "Project: ${PWD}/CLAUDE.md (will be created)")
    fi
    options+=("custom" "Custom path...")
    echo "${options[@]}"
}

prompt_target_claude_md() {
    if [[ -n "$CLAUDE_MD_TARGET" ]]; then
        return
    fi

    if [[ "$USE_GLOBAL" == true ]]; then
        CLAUDE_MD_TARGET="${HOME}/.claude/CLAUDE.md"
        return
    fi

    echo ""
    log_info "Which CLAUDE.md should I modify?"
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

validate_vault() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        log_err "Vault path does not exist or is not a directory: $path"
        exit 1
    fi
    local md_count
    md_count=$(find "$path" -maxdepth 2 -name "*.md" -not -path '*/\.*' | wc -l | tr -d ' ')
    if [[ "$md_count" -eq 0 ]]; then
        log_warn "No .md files found in vault (within 2 levels). Make sure this is your Obsidian vault."
        if [[ "$SKIP_CONFIRM" != true ]]; then
            read -rp "Continue anyway? [y/N] " confirm
            [[ "${confirm,,}" == "y" ]] || exit 0
        fi
    else
        log_ok "Found ${md_count} markdown file(s) in vault."
    fi
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local bak="${file}.bak.$(date +%s)"
        cp "$file" "$bak"
        echo "$bak"
    fi
}

rollback_on_error() {
    local code=$?
    if [[ $code -ne 0 ]]; then
        log_err "Installation failed with exit code ${code}. Rolling back..."
        if [[ -n "${CLAUDE_MD_BACKUP:-}" && -f "$CLAUDE_MD_BACKUP" ]]; then
            cp "$CLAUDE_MD_BACKUP" "$CLAUDE_MD_TARGET"
            log_info "Restored CLAUDE.md from backup."
        fi
        if [[ -n "${SETTINGS_BACKUP:-}" && -f "$SETTINGS_BACKUP" ]]; then
            cp "$SETTINGS_BACKUP" "$SETTINGS_FILE"
            log_info "Restored settings.json from backup."
        fi
        exit $code
    fi
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--vault)
            VAULT_PATH="$2"
            shift 2
            ;;
        -c|--claude-md)
            CLAUDE_MD_TARGET="$2"
            shift 2
            ;;
        -g|--global)
            USE_GLOBAL=true
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
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

# --- Validate inputs ---
check_python

if [[ -z "$VAULT_PATH" ]]; then
    echo ""
    log_info "Path to your Obsidian vault?"
    read -rp "Vault path: " VAULT_PATH
    if [[ -z "$VAULT_PATH" ]]; then
        log_err "Vault path is required."
        exit 1
    fi
fi

# Expand ~ in vault path
VAULT_PATH="${VAULT_PATH/#\~/$HOME}"
validate_vault "$VAULT_PATH"
VAULT_PATH="$(cd "$VAULT_PATH" && pwd)"

prompt_target_claude_md
CLAUDE_MD_TARGET="${CLAUDE_MD_TARGET/#\~/$HOME}"

# Ensure parent directory exists for CLAUDE.md
mkdir -p "$(dirname "$CLAUDE_MD_TARGET")"

# --- Confirm ---
if [[ "$SKIP_CONFIRM" != true ]]; then
    echo ""
    log_info "Ready to install with the following configuration:"
    echo "  Vault path:       $VAULT_PATH"
    echo "  CLAUDE.md target: $CLAUDE_MD_TARGET"
    echo "  Python command:   $PYTHON_CMD"
    echo "  MCP server will be installed to: $INSTALL_DIR"
    echo ""
    read -rp "Proceed? [y/N] " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        log_info "Installation cancelled."
        exit 0
    fi
fi

# --- Install ---
trap rollback_on_error EXIT

# 1. Deploy MCP server
log_info "Deploying MCP server..."
mkdir -p "$INSTALL_DIR"

# Copy mcp_server.py from repo or embed
if [[ -f "${SCRIPT_DIR}/mcp_server.py" ]]; then
    cp "${SCRIPT_DIR}/mcp_server.py" "${INSTALL_DIR}/mcp_server.py"
else
    log_err "mcp_server.py not found in script directory (${SCRIPT_DIR})."
    log_err "Make sure install.sh and mcp_server.py are in the same folder."
    exit 1
fi
chmod +x "${INSTALL_DIR}/mcp_server.py"
log_ok "MCP server installed to ${INSTALL_DIR}/mcp_server.py"

# 2. Register MCP in Claude Code settings
log_info "Registering MCP in Claude Code settings..."
mkdir -p "$(dirname "$SETTINGS_FILE")"

SETTINGS_BACKUP=$(backup_file "$SETTINGS_FILE")

"$PYTHON_CMD" - "$SETTINGS_FILE" "$INSTALL_DIR/mcp_server.py" "$VAULT_PATH" <<'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
server_path = sys.argv[2]
vault_path = sys.argv[3]

if os.path.exists(settings_path):
    with open(settings_path, 'r', encoding='utf-8') as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError:
            data = {}
else:
    data = {}

if 'mcpServers' not in data:
    data['mcpServers'] = {}

data['mcpServers']['obsidian-vault-mcp'] = {
    'command': sys.executable,
    'args': [server_path, '--vault', vault_path]
}

with open(settings_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF

log_ok "MCP registered in ${SETTINGS_FILE}"

# 3. Mutate CLAUDE.md
log_info "Updating ${CLAUDE_MD_TARGET}..."

CLAUDE_MD_BACKUP=$(backup_file "$CLAUDE_MD_TARGET")

BRIDGE_SECTION=$(cat <<EOF
${MARKER_START}
## Obsidian Domain Context

Before modifying any code, writing tests, or making architectural decisions, you MUST consult the Obsidian vault for domain context. Use the \`obsidian-vault-mcp\` tools:

1. **Search** (\`search_vault\`): Look for notes related to the current task using keywords from filenames, module names, and business domain terms.
2. **Read** (\`read_note\`): Read relevant notes fully before proceeding.
3. **List** (\`list_notes\`): If unsure where domain knowledge lives, browse the vault structure.

The vault contains authoritative business rules, architecture decisions, API contracts, and domain terminology. Treat it as the source of truth for this project's domain layer.

Vault root: \`${VAULT_PATH}\`
${MARKER_END}
EOF
)

"$PYTHON_CMD" - "$CLAUDE_MD_TARGET" "$BRIDGE_SECTION" "$MARKER_START" "$MARKER_END" <<'PYEOF'
import sys

path = sys.argv[1]
section = sys.argv[2]
marker_start = sys.argv[3]
marker_end = sys.argv[4]

if path and os.path.exists(path):
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
else:
    content = ""

start_idx = content.find(marker_start)
if start_idx != -1:
    end_idx = content.find(marker_end)
    if end_idx != -1:
        end_idx += len(marker_end)
        new_content = content[:start_idx] + section + content[end_idx:]
    else:
        # Malformed: replace from start to end
        new_content = content[:start_idx] + section
else:
    if content and not content.endswith("\n"):
        content += "\n"
    if content and not content.endswith("\n\n"):
        content += "\n"
    new_content = content + section + "\n"

with open(path, 'w', encoding='utf-8') as f:
    f.write(new_content)
PYEOF

log_ok "CLAUDE.md updated"

trap - EXIT

# --- Summary ---
echo ""
echo "========================================"
echo "  Obsidian-Claude Bridge v${VERSION}"
echo "  Installation complete!"
echo "========================================"
echo ""
echo "  Vault:      ${VAULT_PATH}"
echo "  CLAUDE.md:  ${CLAUDE_MD_TARGET}"
echo "  Settings:   ${SETTINGS_FILE}"
echo "  MCP server: ${INSTALL_DIR}/mcp_server.py"
echo ""
echo "Next steps:"
echo "  1. Restart Claude Code or start a new session."
echo "  2. Run '/mcp' to refresh available tools."
echo "  3. The agent will now search your vault before coding."
echo ""
echo "To uninstall: ./uninstall.sh"
