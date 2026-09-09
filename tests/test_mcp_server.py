"""Tests for mcp_server.py. Run: python3 -m unittest discover tests"""

import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from mcp_server import VaultMCPServer  # noqa: E402


def rpc(server, method, params=None, req_id=1):
    stdin = io.StringIO(json.dumps({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}}) + "\n")
    stdout = io.StringIO()
    server.run(stdin, stdout)
    return json.loads(stdout.getvalue())


def tool(server, name, arguments):
    resp = rpc(server, "tools/call", {"name": name, "arguments": arguments})
    result = resp["result"]
    if result.get("isError"):
        return result
    return json.loads(result["content"][0]["text"])


class VaultServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.vault = self.tmp.name
        os.makedirs(os.path.join(self.vault, "Architecture"))
        os.makedirs(os.path.join(self.vault, ".obsidian"))
        self._write("Architecture/Auth.md", "# Auth\nWe use JWT tokens with refresh rotation.")
        self._write("Glossary.md", "Tenant: a customer organisation. Auth is per tenant.")
        self._write("Architecture/notes.txt", "not markdown")
        self._write(".obsidian/hidden.md", "auth secret workspace config")
        # sibling directory sharing the vault path as prefix (startswith() trap)
        self.sibling = self.vault + "2"
        os.makedirs(self.sibling)
        self._write_abs(os.path.join(self.sibling, "Leak.md"), "should never be readable")
        self.server = VaultMCPServer(self.vault)

    def tearDown(self):
        self.tmp.cleanup()
        import shutil
        shutil.rmtree(self.sibling, ignore_errors=True)

    def _write(self, rel, text):
        self._write_abs(os.path.join(self.vault, rel), text)

    @staticmethod
    def _write_abs(path, text):
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    # --- protocol -----------------------------------------------------------

    def test_initialize_handshake(self):
        resp = rpc(self.server, "initialize", {"protocolVersion": "2025-03-26", "capabilities": {}})
        self.assertEqual(resp["id"], 1)
        self.assertEqual(resp["result"]["protocolVersion"], "2025-03-26")
        self.assertIn("tools", resp["result"]["capabilities"])
        self.assertEqual(resp["result"]["serverInfo"]["name"], "obsidian-vault-mcp")

    def test_notification_gets_no_response(self):
        stdout = io.StringIO()
        self.server.run(io.StringIO('{"jsonrpc":"2.0","method":"notifications/initialized"}\n'), stdout)
        self.assertEqual(stdout.getvalue(), "")

    def test_ping(self):
        self.assertEqual(rpc(self.server, "ping")["result"], {})

    def test_unknown_method_is_jsonrpc_error(self):
        resp = rpc(self.server, "nope")
        self.assertEqual(resp["error"]["code"], -32601)

    def test_parse_error(self):
        stdout = io.StringIO()
        self.server.run(io.StringIO("{not json\n"), stdout)
        self.assertEqual(json.loads(stdout.getvalue())["error"]["code"], -32700)

    def test_tools_list(self):
        names = [t["name"] for t in rpc(self.server, "tools/list")["result"]["tools"]]
        self.assertEqual(names, ["search_vault", "read_note", "list_notes"])

    # --- search -------------------------------------------------------------

    def test_search_ranks_title_before_content(self):
        hits = tool(self.server, "search_vault", {"query": "auth"})
        self.assertEqual([h["path"] for h in hits], ["Architecture/Auth.md", "Glossary.md"])
        self.assertTrue(hits[0]["preview"].startswith("# Auth"))

    def test_search_skips_hidden_and_non_markdown(self):
        paths = [h["path"] for h in tool(self.server, "search_vault", {"query": "workspace"})]
        self.assertEqual(paths, [])

    def test_search_max_results_accepts_float_from_json(self):
        hits = tool(self.server, "search_vault", {"query": "auth", "max_results": 1.0})
        self.assertEqual(len(hits), 1)

    def test_search_empty_query_is_tool_error(self):
        result = tool(self.server, "search_vault", {"query": "   "})
        self.assertTrue(result["isError"])

    # --- read ---------------------------------------------------------------

    def test_read_note(self):
        note = tool(self.server, "read_note", {"path": "Architecture/Auth.md"})
        self.assertIn("JWT", note["content"])

    def test_read_note_blocks_traversal(self):
        result = tool(self.server, "read_note", {"path": "../" + os.path.basename(self.sibling) + "/Leak.md"})
        self.assertTrue(result["isError"])

    def test_read_note_blocks_absolute_path(self):
        result = tool(self.server, "read_note", {"path": os.path.join(self.sibling, "Leak.md")})
        self.assertTrue(result["isError"])

    def test_read_note_directory_is_error(self):
        self.assertTrue(tool(self.server, "read_note", {"path": "Architecture"})["isError"])

    # --- list ---------------------------------------------------------------

    def test_list_root_directories_first_hidden_skipped(self):
        entries = tool(self.server, "list_notes", {})
        self.assertEqual([e["name"] for e in entries], ["Architecture", "Glossary.md"])

    def test_list_subdirectory_only_markdown(self):
        entries = tool(self.server, "list_notes", {"directory": "Architecture"})
        self.assertEqual([e["path"] for e in entries], ["Architecture/Auth.md"])


if __name__ == "__main__":
    unittest.main()
