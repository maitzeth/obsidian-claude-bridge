#!/usr/bin/env bash
# Obsidian-Claude Bridge Installer
# Connects Claude Code with your Obsidian vault for automatic domain context.
# Compatible with bash 3.2+ (stock macOS), Linux, WSL and Git Bash.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.1.0"
SERVER_NAME="obsidian-vault-mcp"
MARKER_START="<!-- obsidian-bridge:v1 — do not edit between markers — use: ./uninstall.sh -->"
MARKER_END="<!-- /obsidian-bridge:v1 -->"
INSTALL_DIR="${HOME}/.config/obsidian-claude-bridge"
USER_MCP_FILE="${HOME}/.claude.json"

# --- Defaults ---
VAULT_PATH=""
CLAUDE_MD_TARGET=""
USE_GLOBAL=false
PROJECT_DIR=""
MCP_SCOPE=""          # user | local | project (derived when empty)
MCP_FILE=""
SKIP_CONFIRM=false
PYTHON_CMD=""
CLAUDE_MD_BACKUP=""
MCP_BACKUP=""
CLAUDE_MD_TOUCHED=false
MCP_TOUCHED=false

# --- Helpers ---
print_help() {
    cat <<HELP
Obsidian-Claude Bridge Installer v${VERSION}

Usage: ./install.sh [OPTIONS]

Options:
  -v, --vault PATH      Path to your Obsidian vault directory
  -c, --claude-md PATH  Path to target CLAUDE.md (default: ask)
  -g, --global          Use global CLAUDE.md (~/.claude/CLAUDE.md)
  -p, --project DIR     Project directory (implies a per-project install)
  -s, --scope SCOPE     Where to register the MCP server:
                          user     -> ~/.claude.json, every project
                          local    -> ~/.claude.json, this project, only you
                          project  -> <project>/.mcp.json, shared with your team
                        Default: user for global CLAUDE.md, local for --project
  -y, --yes             Skip confirmation prompts
  -h, --help            Show this help message

Examples:
  ./install.sh --vault ~/Documents/ObsidianVault
  ./install.sh --vault ~/Vault --global --yes
  ./install.sh --vault ~/Vault --project ~/code/my-app            # private
  ./install.sh --vault ~/Vault --project ~/code/my-app --scope project  # team
HELP
}

log_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$1"; }
log_ok()   { printf '\033[1;32m[OK]\033[0m   %s\n' "$1"; }
log_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
log_err()  { printf '\033[1;31m[ERR]\033[0m  %s\n' "$1" >&2; }

is_yes() { [[ "$1" == [yY] || "$1" == [yY][eE][sS] ]]; }

expand_tilde() { printf '%s' "${1/#\~/$HOME}"; }

check_python() {
    local candidate
    for candidate in python3 python py; do
        if command -v "$candidate" >/dev/null 2>&1 &&
           "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
            PYTHON_CMD="$candidate"
            break
        fi
    done
    if [[ -z "$PYTHON_CMD" ]]; then
        log_err "Python 3.8+ is required but was not found (tried: python3, python, py)."
        exit 1
    fi
    local pyver
    pyver=$("$PYTHON_CMD" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    log_info "Found Python ${pyver} (${PYTHON_CMD})"
}

require_arg() {
    # $1 = option name, $2 = number of remaining args
    if [[ "$2" -lt 2 ]]; then
        log_err "Option $1 requires a value."
        exit 1
    fi
}

prompt_project_dir() {
    read -rp "Project directory [${PWD}]: " PROJECT_DIR
    PROJECT_DIR="$(expand_tilde "${PROJECT_DIR:-$PWD}")"
    if [[ ! -d "$PROJECT_DIR" ]]; then
        log_err "Project directory does not exist: $PROJECT_DIR"
        exit 1
    fi
}

prompt_target_claude_md() {
    if [[ "$USE_GLOBAL" == true && -z "$CLAUDE_MD_TARGET" ]]; then
        CLAUDE_MD_TARGET="${HOME}/.claude/CLAUDE.md"
    fi
    [[ -n "$CLAUDE_MD_TARGET" || -n "$PROJECT_DIR" ]] && return

    echo ""
    log_info "Where should Claude use this vault?"
    echo "  1) Every project            -> ~/.claude/CLAUDE.md + ~/.claude.json"
    echo "  2) One project, only me     -> <project>/CLAUDE.local.md + ~/.claude.json (nothing to commit)"
    echo "  3) One project, whole team  -> <project>/CLAUDE.md + <project>/.mcp.json (commit both)"
    echo "  4) Custom CLAUDE.md path"
    echo ""
    read -rp "Choice [1-4, default: 1]: " choice
    case "${choice:-1}" in
        2) prompt_project_dir; MCP_SCOPE="${MCP_SCOPE:-local}" ;;
        3) prompt_project_dir; MCP_SCOPE="${MCP_SCOPE:-project}" ;;
        4) read -rp "Enter full path to CLAUDE.md: " CLAUDE_MD_TARGET ;;
        *) CLAUDE_MD_TARGET="${HOME}/.claude/CLAUDE.md" ;;
    esac
    if [[ -z "$CLAUDE_MD_TARGET" && -z "$PROJECT_DIR" ]]; then
        log_err "CLAUDE.md path is required."
        exit 1
    fi
}

resolve_mcp_scope() {
    if [[ -n "$PROJECT_DIR" ]]; then
        MCP_SCOPE="${MCP_SCOPE:-local}"
        if [[ -z "$CLAUDE_MD_TARGET" ]]; then
            case "$MCP_SCOPE" in
                local) CLAUDE_MD_TARGET="${PROJECT_DIR}/CLAUDE.local.md" ;;
                *)     CLAUDE_MD_TARGET="${PROJECT_DIR}/CLAUDE.md" ;;
            esac
        fi
    elif [[ -z "$MCP_SCOPE" ]]; then
        if [[ "$CLAUDE_MD_TARGET" == "${HOME}/.claude/CLAUDE.md" ]]; then
            MCP_SCOPE="user"
        else
            MCP_SCOPE="project"
        fi
    fi
    [[ -n "$PROJECT_DIR" ]] || PROJECT_DIR="$(dirname "$CLAUDE_MD_TARGET")"
    case "$MCP_SCOPE" in
        user|local) MCP_FILE="$USER_MCP_FILE" ;;
        project)    MCP_FILE="${PROJECT_DIR}/.mcp.json" ;;
        *)
            log_err "Invalid --scope '${MCP_SCOPE}'. Use 'user', 'local' or 'project'."
            exit 1
            ;;
    esac
}

ensure_gitignored() {
    # $1 = project dir, $2 = file name. Only acts inside a git repo.
    local dir="$1" name="$2"
    command -v git >/dev/null 2>&1 || return 0
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    if git -C "$dir" check-ignore -q "$name" 2>/dev/null; then
        return 0
    fi
    [[ -f "${dir}/.gitignore" && -s "${dir}/.gitignore" && "$(tail -c1 "${dir}/.gitignore")" != "" ]] && echo >> "${dir}/.gitignore"
    echo "$name" >> "${dir}/.gitignore"
    log_ok "Added ${name} to ${dir}/.gitignore"
}

validate_vault() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        log_err "Vault path does not exist or is not a directory: $path"
        exit 1
    fi
    local md_count
    md_count=$(find "$path" -maxdepth 3 -name '*.md' -not -path '*/.*' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$md_count" -eq 0 ]]; then
        log_warn "No .md files found in vault (within 3 levels). Make sure this is your Obsidian vault."
        if [[ "$SKIP_CONFIRM" != true ]]; then
            read -rp "Continue anyway? [y/N] " confirm
            is_yes "${confirm:-n}" || exit 0
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
        printf '%s' "$bak"
    fi
}

restore_or_remove() {
    # $1 = backup path (may be empty), $2 = live file, $3 = label
    if [[ -n "$1" && -f "$1" ]]; then
        cp "$1" "$2" && log_info "Restored $3 from backup."
    elif [[ -f "$2" ]]; then
        rm -f "$2" && log_info "Removed newly created $3."
    fi
}

rollback_on_error() {
    local code=$?
    if [[ $code -ne 0 ]]; then
        log_err "Installation failed with exit code ${code}. Rolling back..."
        # Only touch files whose mutation actually started (backup taken).
        [[ "$CLAUDE_MD_TOUCHED" == true ]] && restore_or_remove "$CLAUDE_MD_BACKUP" "$CLAUDE_MD_TARGET" "CLAUDE.md"
        [[ "$MCP_TOUCHED" == true ]] && restore_or_remove "$MCP_BACKUP" "$MCP_FILE" "$(basename "$MCP_FILE")"
        exit "$code"
    fi
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--vault)     require_arg "$1" $#; VAULT_PATH="$2"; shift 2 ;;
        -c|--claude-md) require_arg "$1" $#; CLAUDE_MD_TARGET="$2"; shift 2 ;;
        -p|--project)   require_arg "$1" $#; PROJECT_DIR="$2"; shift 2 ;;
        -s|--scope)     require_arg "$1" $#; MCP_SCOPE="$2"; shift 2 ;;
        -g|--global)    USE_GLOBAL=true; shift ;;
        -y|--yes)       SKIP_CONFIRM=true; shift ;;
        -h|--help)      print_help; exit 0 ;;
        *)
            log_err "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

# --- Validate inputs ---
check_python

if [[ ! -f "${SCRIPT_DIR}/mcp_server.py" ]]; then
    log_err "mcp_server.py not found next to install.sh (${SCRIPT_DIR})."
    exit 1
fi

if [[ -z "$VAULT_PATH" ]]; then
    echo ""
    read -rp "Path to your Obsidian vault: " VAULT_PATH
    if [[ -z "$VAULT_PATH" ]]; then
        log_err "Vault path is required."
        exit 1
    fi
fi

VAULT_PATH="$(expand_tilde "$VAULT_PATH")"
validate_vault "$VAULT_PATH"
VAULT_PATH="$(cd "$VAULT_PATH" && pwd -P)"

prompt_target_claude_md
if [[ -n "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(expand_tilde "$PROJECT_DIR")"
    [[ -d "$PROJECT_DIR" ]] || { log_err "Project directory does not exist: $PROJECT_DIR"; exit 1; }
    PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
fi
resolve_mcp_scope
CLAUDE_MD_TARGET="$(expand_tilde "$CLAUDE_MD_TARGET")"
# Normalise to an absolute path without requiring the file to exist yet.
CLAUDE_MD_TARGET="$("$PYTHON_CMD" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$CLAUDE_MD_TARGET")"
PROJECT_DIR="$(dirname "$CLAUDE_MD_TARGET")"

# --- Confirm ---
if [[ "$SKIP_CONFIRM" != true ]]; then
    echo ""
    log_info "Ready to install with the following configuration:"
    echo "  Vault path:       $VAULT_PATH"
    echo "  CLAUDE.md target: $CLAUDE_MD_TARGET"
    echo "  MCP scope:        $MCP_SCOPE  -> $MCP_FILE"
    echo "  Python command:   $PYTHON_CMD"
    echo "  MCP server path:  $INSTALL_DIR/mcp_server.py"
    echo ""
    read -rp "Proceed? [y/N] " confirm
    if ! is_yes "${confirm:-n}"; then
        log_info "Installation cancelled."
        exit 0
    fi
fi

# --- Install ---
trap rollback_on_error EXIT

# 1. Deploy MCP server
log_info "Deploying MCP server..."
mkdir -p "$INSTALL_DIR"
cp "${SCRIPT_DIR}/mcp_server.py" "${INSTALL_DIR}/mcp_server.py"
chmod +x "${INSTALL_DIR}/mcp_server.py"
log_ok "MCP server installed to ${INSTALL_DIR}/mcp_server.py"

# 2. Register MCP server with Claude Code
log_info "Registering '${SERVER_NAME}' in ${MCP_FILE} (${MCP_SCOPE} scope)..."
mkdir -p "$(dirname "$MCP_FILE")"
MCP_BACKUP="$(backup_file "$MCP_FILE")"
MCP_TOUCHED=true

"$PYTHON_CMD" - "$MCP_FILE" "$SERVER_NAME" "$INSTALL_DIR/mcp_server.py" "$VAULT_PATH" "$MCP_SCOPE" "$PROJECT_DIR" <<'PYEOF'
import json, os, sys

config_path, server_name, server_path, vault_path, scope, project_dir = sys.argv[1:7]

data = {}
if os.path.exists(config_path):
    with open(config_path, "r", encoding="utf-8") as f:
        raw = f.read()
    if raw.strip():
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as e:
            sys.exit(f"Refusing to overwrite malformed JSON in {config_path}: {e}")
    if not isinstance(data, dict):
        sys.exit(f"Refusing to modify {config_path}: top-level value is not an object")

# sys.executable is the interpreter that passed the version check.
# Warn if it lives inside a virtualenv that may disappear later.
if sys.prefix != getattr(sys, "base_prefix", sys.prefix):
    print(f"[WARN] Registering the virtualenv interpreter {sys.executable}; "
          "if you delete this venv the MCP server will stop working.", file=sys.stderr)

if scope == "local":
    # Claude Code keeps per-project private servers under projects[<abs path>].
    container = data.setdefault("projects", {}).setdefault(project_dir, {})
else:
    container = data
servers = container.setdefault("mcpServers", {})
servers[server_name] = {
    "type": "stdio",
    "command": sys.executable,
    "args": [server_path, "--vault", vault_path],
}

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

log_ok "MCP server registered"

# 3. Add instructions to CLAUDE.md
log_info "Updating ${CLAUDE_MD_TARGET}..."
mkdir -p "$(dirname "$CLAUDE_MD_TARGET")"
CLAUDE_MD_BACKUP="$(backup_file "$CLAUDE_MD_TARGET")"
CLAUDE_MD_TOUCHED=true

# read -d '' is used instead of $(cat <<EOF) because bash 3.2 mis-parses
# heredocs containing apostrophes inside command substitution.
BRIDGE_SECTION=""
read -r -d '' BRIDGE_SECTION <<SECTION || true
${MARKER_START}
## Obsidian Domain Context

Before modifying any code, writing tests, or making architectural decisions, you MUST consult the Obsidian vault for domain context. Use the \`${SERVER_NAME}\` tools:

1. **Search** (\`search_vault\`): Look for notes related to the current task using keywords from filenames, module names, and business domain terms.
2. **Read** (\`read_note\`): Read relevant notes fully before proceeding.
3. **List** (\`list_notes\`): If unsure where domain knowledge lives, browse the vault structure.

The vault contains authoritative business rules, architecture decisions, API contracts, and domain terminology. Treat it as the source of truth for this project's domain layer.

Vault root: \`${VAULT_PATH}\`
${MARKER_END}
SECTION
BRIDGE_SECTION="${BRIDGE_SECTION%$'\n'}"

"$PYTHON_CMD" - "$CLAUDE_MD_TARGET" "$BRIDGE_SECTION" "$MARKER_START" "$MARKER_END" <<'PYEOF'
import os, sys

path, section, marker_start, marker_end = sys.argv[1:5]

content = ""
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

start_idx = content.find(marker_start)
if start_idx != -1:
    end_idx = content.find(marker_end, start_idx)
    if end_idx != -1:
        new_content = content[:start_idx] + section + content[end_idx + len(marker_end):]
    else:
        # Malformed section (no end marker): replace from the start marker onward.
        new_content = content[:start_idx] + section + "\n"
else:
    if content and not content.endswith("\n"):
        content += "\n"
    if content and not content.endswith("\n\n"):
        content += "\n"
    new_content = content + section + "\n"

with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)
PYEOF

log_ok "$(basename "$CLAUDE_MD_TARGET") updated"
[[ "$MCP_SCOPE" == "local" ]] && ensure_gitignored "$PROJECT_DIR" "$(basename "$CLAUDE_MD_TARGET")"

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
echo "  MCP config: ${MCP_FILE} (${MCP_SCOPE} scope)"
echo "  MCP server: ${INSTALL_DIR}/mcp_server.py"
echo ""
echo "Next steps:"
echo "  1. Restart Claude Code (or start a new session)."
case "$MCP_SCOPE" in
    project) echo "  2. Open Claude Code inside ${PROJECT_DIR} and approve the project MCP server when prompted." ;;
    local)   echo "  2. Open Claude Code inside ${PROJECT_DIR} and run '/mcp' to confirm '${SERVER_NAME}' is connected." ;;
    *)       echo "  2. Run '/mcp' to confirm '${SERVER_NAME}' is connected." ;;
esac
echo "  3. The agent will now search your vault before coding."
echo ""
echo "To uninstall: ./uninstall.sh --all"
