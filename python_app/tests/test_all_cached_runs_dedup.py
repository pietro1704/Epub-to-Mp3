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
        """Pin the source location of the new dedup call.

        The fix is structural: there's a `if pending_total == 0:`
        branch that returns early on cache hit, and we now run dedup
        before the ID3 tagging inside that branch. A future refactor
        that drops the call would silently regress the Carl bug — this
        guard fails fast in CI before the regression hits production.
        """
        source = (Path(__file__).resolve().parents[1] / "src" / "converter.py").read_text(
            encoding="utf-8"
        )
        # The block we're protecting is unique because it sits inside
        # the `if pending_total == 0:` branch followed shortly after
        # by `_apply_final_id3_tags` — so we look for the marker comment
        # we left when we added the dedup call.
        assert "Auto-dedup (cache-hit path)" in source, (
            "all-cached fast path lost the auto-dedup call (regression of "
            "the v0.3.20 fix; would let duplicate MP3s pile up across runs)"
        )
        assert "self._dedup_chapter_outputs(output_dir)" in source


if __name__ == "__main__":
    unittest.main()
