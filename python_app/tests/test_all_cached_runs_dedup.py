"""All-cached fast path now runs auto-dedup.

The Carl conversion accumulated 64 MP3s for a 61-chapter book because
the all-cached fast path in `_convert_chapters_parallel` returned
without ever invoking `_dedup_chapter_outputs`. v0.3.20 wires dedup
into that path so duplicates from earlier runs are collapsed even when
no chapter actually re-synthesised.

These tests pin the new behaviour: when every chapter is already on
disk, the helper is called against the output dir before the result
is returned.
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


class TestAllCachedRunsDedup(unittest.TestCase):
    def test_converter_inserts_dedup_before_id3_in_fast_path(self):
        """The active cache-hit owner must deduplicate before final ID3 tagging."""
        import ast

        root = Path(__file__).resolve().parents[1] / "src"
        owner = ast.parse((root / "book_engine_preparation.py").read_text(encoding="utf-8"))
        function = next(node for node in owner.body if isinstance(node, ast.AsyncFunctionDef))
        cached = next(
            node for node in function.body
            if isinstance(node, ast.If) and ast.unparse(node.test) == "_state.pending_total == 0"
        )
        calls = [
            node for node in ast.walk(cached)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
        ]
        dedup = next(node for node in calls if node.func.attr == "_dedup_chapter_outputs")
        tags = next(node for node in calls if node.func.attr == "_apply_final_id3_tags")
        self.assertEqual(ast.unparse(dedup.args[0]), "_state.output_dir")
        self.assertLess(dedup.lineno, tags.lineno, "Dedup must precede ID3 tagging")
        returns = [node for node in ast.walk(cached) if isinstance(node, ast.Return)]
        self.assertTrue(returns, "The cache-hit branch must return its completed result")
        self.assertLess(tags.lineno, min(node.lineno for node in returns))
        orchestration = ast.parse((root / "book_conversion_run.py").read_text(encoding="utf-8"))
        self.assertTrue(any(
            isinstance(node, ast.Await) and isinstance(node.value, ast.Call)
            and isinstance(node.value.func, ast.Name)
            and node.value.func.id == "_book_engine_preparation"
            for node in ast.walk(orchestration)
        ), "The actual book orchestration must still execute the cache-hit owner")


if __name__ == "__main__":
    unittest.main()
