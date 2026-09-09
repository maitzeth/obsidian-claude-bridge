#!/usr/bin/env python3
"""
Obsidian Vault MCP Server
Exposes an Obsidian vault (a folder of markdown files) to Claude Code through
the Model Context Protocol over stdio (newline-delimited JSON-RPC 2.0).

Python 3.8+ stdlib only. No external dependencies.
"""

import argparse
import json
import os
import sys

SERVER_NAME = "obsidian-vault-mcp"
SERVER_VERSION = "1.1.0"
PROTOCOL_VERSION = "2024-11-05"

PREVIEW_CHARS = 2000        # characters returned per search hit
CONTENT_SCAN_CHARS = 200_000  # how much of each note is scanned for content matches
DEFAULT_MAX_RESULTS = 10
MAX_RESULTS_CAP = 50

# JSON-RPC error codes
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603


class JsonRpcError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


TOOLS = [
    {
        "name": "search_vault",
        "description": (
            "Search Obsidian vault notes by keyword. Matches on filename first "
            "(higher rank), then on note content. Returns path, title and a preview."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Case-insensitive keyword or phrase"},
                "max_results": {
                    "type": "integer",
                    "default": DEFAULT_MAX_RESULTS,
                    "minimum": 1,
                    "maximum": MAX_RESULTS_CAP,
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "read_note",
        "description": "Read the full content of a single note. Path is relative to the vault root.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "e.g. Architecture/Auth.md"},
            },
            "required": ["path"],
        },
    },
    {
        "name": "list_notes",
        "description": "List notes and folders in a directory of the vault (vault root by default).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "directory": {"type": "string", "default": "", "description": "Relative directory path"},
            },
        },
    },
]


class VaultMCPServer:
    def __init__(self, vault_path: str):
        self.vault_path = os.path.realpath(vault_path)
        if not os.path.isdir(self.vault_path):
            raise ValueError(f"Vault path is not a directory: {vault_path}")

    # ------------------------------------------------------------------ paths

    def _safe_path(self, rel_path: str) -> str:
        """Resolve a vault-relative path. Blocks traversal and symlink escapes."""
        if os.path.isabs(rel_path):
            raise JsonRpcError(INVALID_PARAMS, "Path must be relative to the vault root")
        target = os.path.realpath(os.path.join(self.vault_path, rel_path))
        try:
            inside = os.path.commonpath([self.vault_path, target]) == self.vault_path
        except ValueError:  # different drives on Windows
            inside = False
        if not inside:
            raise JsonRpcError(INVALID_PARAMS, "Path escapes the vault; access denied")
        return target

    @staticmethod
    def _read_text(full_path: str, limit: int) -> str:
        with open(full_path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(limit)

    # ------------------------------------------------------------------ tools

    def search_vault(self, query: str, max_results: int = DEFAULT_MAX_RESULTS):
        query_lower = query.strip().lower()
        if not query_lower:
            raise JsonRpcError(INVALID_PARAMS, "query must not be empty")
        max_results = max(1, min(int(max_results), MAX_RESULTS_CAP))

        title_hits, content_hits = [], []
        for root, dirs, files in os.walk(self.vault_path):
            dirs[:] = sorted(d for d in dirs if not d.startswith("."))
            for name in sorted(files):
                if not name.lower().endswith(".md") or name.startswith("."):
                    continue
                full_path = os.path.join(root, name)
                rel_path = os.path.relpath(full_path, self.vault_path).replace(os.sep, "/")
                title = name[:-3]
                try:
                    text = self._read_text(full_path, CONTENT_SCAN_CHARS)
                except OSError:
                    continue
                hit = {"path": rel_path, "title": title, "preview": text[:PREVIEW_CHARS]}
                if query_lower in title.lower():
                    title_hits.append(hit)
                elif query_lower in text.lower():
                    content_hits.append(hit)
                if len(title_hits) >= max_results:
                    return title_hits[:max_results]
        return (title_hits + content_hits)[:max_results]

    def read_note(self, path: str):
        if not path:
            raise JsonRpcError(INVALID_PARAMS, "path is required")
        safe = self._safe_path(path)
        if not os.path.isfile(safe):
            raise JsonRpcError(INVALID_PARAMS, f"Note not found: {path}")
        with open(safe, "r", encoding="utf-8", errors="replace") as f:
            return {"path": path, "content": f.read()}

    def list_notes(self, directory: str = ""):
        target = self._safe_path(directory) if directory else self.vault_path
        if not os.path.isdir(target):
            raise JsonRpcError(INVALID_PARAMS, f"Not a directory: {directory}")
        entries = []
        for entry in os.listdir(target):
            if entry.startswith("."):
                continue
            full = os.path.join(target, entry)
            is_dir = os.path.isdir(full)
            if not is_dir and not entry.lower().endswith(".md"):
                continue
            rel = os.path.relpath(full, self.vault_path).replace(os.sep, "/")
            entries.append({"name": entry, "path": rel, "is_directory": is_dir})
        return sorted(entries, key=lambda e: (not e["is_directory"], e["name"].lower()))

    # ------------------------------------------------------------------ protocol

    def _call_tool(self, name: str, args: dict):
        if name == "search_vault":
            return self.search_vault(
                str(args.get("query", "")), args.get("max_results", DEFAULT_MAX_RESULTS)
            )
        if name == "read_note":
            return self.read_note(str(args.get("path", "")))
        if name == "list_notes":
            return self.list_notes(str(args.get("directory", "")))
        raise JsonRpcError(INVALID_PARAMS, f"Unknown tool: {name}")

    def handle_request(self, method: str, params: dict):
        if method == "initialize":
            return {
                "protocolVersion": params.get("protocolVersion") or PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            }
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": TOOLS}
        if method == "tools/call":
            name = params.get("name")
            args = params.get("arguments") or {}
            if not isinstance(args, dict):
                raise JsonRpcError(INVALID_PARAMS, "arguments must be an object")
            try:
                result = self._call_tool(name, args)
            except JsonRpcError as e:
                # Tool-level failures are reported inside the result so the model can react.
                return {"isError": True, "content": [{"type": "text", "text": e.message}]}
            return {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False, indent=2)}]}
        raise JsonRpcError(METHOD_NOT_FOUND, f"Method not found: {method}")

    def _dispatch(self, req):
        if not isinstance(req, dict) or req.get("jsonrpc") != "2.0" or not isinstance(req.get("method"), str):
            return {"jsonrpc": "2.0", "id": None,
                    "error": {"code": INVALID_REQUEST, "message": "Invalid JSON-RPC request"}}
        method = req["method"]
        params = req.get("params") or {}
        is_notification = "id" not in req
        try:
            result = self.handle_request(method, params)
        except JsonRpcError as e:
            if is_notification:
                return None
            return {"jsonrpc": "2.0", "id": req["id"], "error": {"code": e.code, "message": e.message}}
        except Exception as e:  # noqa: BLE001 - never crash the transport
            if is_notification:
                return None
            return {"jsonrpc": "2.0", "id": req["id"],
                    "error": {"code": INTERNAL_ERROR, "message": f"{type(e).__name__}: {e}"}}
        if is_notification:  # e.g. notifications/initialized — never answered
            return None
        return {"jsonrpc": "2.0", "id": req["id"], "result": result}

    def run(self, stdin=None, stdout=None):
        stdin = stdin or sys.stdin
        stdout = stdout or sys.stdout
        for line in stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except json.JSONDecodeError:
                resp = {"jsonrpc": "2.0", "id": None,
                        "error": {"code": PARSE_ERROR, "message": "Parse error"}}
            else:
                resp = self._dispatch(req)
            if resp is not None:
                stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
                stdout.flush()


def main():
    parser = argparse.ArgumentParser(description="Obsidian Vault MCP Server")
    parser.add_argument("--vault", required=True, help="Path to the Obsidian vault directory")
    parser.add_argument("--version", action="version", version=f"{SERVER_NAME} {SERVER_VERSION}")
    args = parser.parse_args()

    # Force UTF-8 on the transport regardless of locale (matters on Windows).
    for stream in (sys.stdin, sys.stdout):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

    try:
        server = VaultMCPServer(args.vault)
    except ValueError as e:
        print(f"[{SERVER_NAME}] {e}", file=sys.stderr)
        sys.exit(2)
    server.run()


if __name__ == "__main__":
    main()
