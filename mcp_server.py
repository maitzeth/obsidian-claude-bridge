#!/usr/bin/env python3
"""
Obsidian Vault MCP Server
Reads markdown files from an Obsidian vault directory.
Python 3.8+ stdlib only. No external dependencies.
"""

import argparse
import json
import os
import sys


class VaultMCPServer:
    def __init__(self, vault_path: str):
        self.vault_path = os.path.abspath(os.path.normpath(vault_path))
        if not os.path.isdir(self.vault_path):
            raise ValueError(f"Vault path is not a directory: {vault_path}")

    def _safe_path(self, rel_path: str) -> str:
        """Resolve a relative path inside the vault. Block traversal."""
        target = os.path.abspath(os.path.normpath(os.path.join(self.vault_path, rel_path)))
        if not target.startswith(self.vault_path):
            raise ValueError("Path traversal attempt blocked")
        return target

    def _read_preview(self, full_path: str, limit: int = 2000) -> str:
        try:
            with open(full_path, "r", encoding="utf-8") as f:
                return f.read(limit)
        except Exception:
            return ""

    def search_vault(self, query: str, max_results: int = 10):
        results = []
        query_lower = query.lower()
        for root, dirs, files in os.walk(self.vault_path):
            # skip hidden directories
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for f in files:
                if not f.endswith(".md"):
                    continue
                full_path = os.path.join(root, f)
                rel_path = os.path.relpath(full_path, self.vault_path)
                title = f[:-3]
                # filename match (higher priority)
                if query_lower in title.lower():
                    preview = self._read_preview(full_path)
                    results.append({
                        "path": rel_path,
                        "title": title,
                        "preview": preview,
                        "score": 2,
                    })
                    continue
                # content match (lower priority, read a bit to search)
                try:
                    with open(full_path, "r", encoding="utf-8") as fh:
                        chunk = fh.read(5000)
                        if query_lower in chunk.lower():
                            preview = chunk[:2000]
                            results.append({
                                "path": rel_path,
                                "title": title,
                                "preview": preview,
                                "score": 1,
                            })
                except Exception:
                    continue
                if len(results) >= max_results * 2:
                    break
            if len(results) >= max_results * 2:
                break

        results.sort(key=lambda x: x["score"], reverse=True)
        return [
            {"path": r["path"], "title": r["title"], "preview": r["preview"]}
            for r in results[:max_results]
        ]

    def read_note(self, path: str):
        safe = self._safe_path(path)
        if not os.path.exists(safe):
            raise FileNotFoundError(f"Note not found: {path}")
        with open(safe, "r", encoding="utf-8") as f:
            return {"content": f.read(), "path": path}

    def list_notes(self, directory: str = ""):
        target = self._safe_path(directory) if directory else self.vault_path
        if not os.path.isdir(target):
            raise ValueError(f"Not a directory: {directory}")
        entries = []
        for entry in os.listdir(target):
            if entry.startswith("."):
                continue
            full = os.path.join(target, entry)
            rel = os.path.relpath(full, self.vault_path)
            entries.append({
                "name": entry,
                "path": rel,
                "is_directory": os.path.isdir(full),
            })
        return sorted(entries, key=lambda x: (not x["is_directory"], x["name"]))

    def handle_request(self, req: dict):
        method = req.get("method")
        params = req.get("params", {})

        if method == "tools/list":
            return {
                "tools": [
                    {
                        "name": "search_vault",
                        "description": "Search Obsidian vault notes by keyword in filename or content",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "query": {"type": "string"},
                                "max_results": {"type": "number", "default": 10},
                            },
                            "required": ["query"],
                        },
                    },
                    {
                        "name": "read_note",
                        "description": "Read the full content of a single note",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string"},
                            },
                            "required": ["path"],
                        },
                    },
                    {
                        "name": "list_notes",
                        "description": "List notes in a directory within the vault",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "directory": {"type": "string", "default": ""},
                            },
                        },
                    },
                ]
            }

        if method == "tools/call":
            name = params.get("name")
            args = params.get("arguments", {})
            try:
                if name == "search_vault":
                    result = self.search_vault(args.get("query", ""), args.get("max_results", 10))
                elif name == "read_note":
                    result = self.read_note(args.get("path", ""))
                elif name == "list_notes":
                    result = self.list_notes(args.get("directory", ""))
                else:
                    return {"error": f"Unknown tool: {name}"}
                return {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False)}]}
            except Exception as e:
                return {"isError": True, "content": [{"type": "text", "text": str(e)}]}

        return {"error": f"Unknown method: {method}"}

    def run(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except json.JSONDecodeError:
                continue
            req_id = req.get("id")
            result = self.handle_request(req)
            resp = {"jsonrpc": "2.0", "id": req_id}
            if "error" in result:
                resp["error"] = {"code": -32601, "message": result["error"]}
            else:
                resp["result"] = result
            print(json.dumps(resp, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description="Obsidian Vault MCP Server")
    parser.add_argument("--vault", required=True, help="Path to the Obsidian vault directory")
    args = parser.parse_args()

    server = VaultMCPServer(args.vault)
    server.run()


if __name__ == "__main__":
    main()
