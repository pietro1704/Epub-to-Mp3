"""`--fallback-engine none` must be respected by every retry path.

The Carl Capa regression (v0.3.21): user passed
``--engine edge --fallback-engine none`` to force a pt-BR audiobook
through Edge only. 60 of 61 chapters came out at 24 kHz (Edge), but
the 4-character "Capa" chapter came out at 16 kHz (Piper).

The retry mixin had two silent fallback paths that ignored the
operator's "none" choice:

1. ``_reconvert_chapters_with_engine``'s candidate-list builder
   appended ``piper`` after ``edge`` regardless of CLI flag.
2. The inner Edge-quick-synthesis catch block jumped straight to
   Piper for any exception when ``"piper" in available_engines``.
3. ``_last_resort_recovery`` swapped the engine to Piper whenever it
   was installed, again ignoring CLI intent.

These tests pin the fix at the source level.
"""

from __future__ import annotations

import inspect
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src._retry_mixin import _RetryMixin


class TestRetryRespectsFallbackNone(unittest.TestCase):
    def test_reconvert_candidate_list_checks_cli_fallback(self):
        """The candidate-list builder must read
        ``self._cli_fallback_engine`` and short-circuit when the
        operator passed ``--fallback-engine none``."""
        # The function name varies across refactors; assert the source
        # of the mixin module references both the flag and the gate.
        from src import _retry_mixin

        src = inspect.getsource(_retry_mixin)
        self.assertIn("_cli_fallback_engine", src)
        self.assertIn('cli_fallback == "none"', src)

    def test_inner_edge_to_piper_swap_checks_cli_fallback(self):
        """The 'edge failed → try piper' inner retry must skip Piper
        when the CLI fallback is 'none'. Pin via marker comment plus a
        guard variable."""
        from src import _retry_mixin

        src = inspect.getsource(_retry_mixin)
        # The fix introduces a piper_allowed gate before the 'and
        # "piper" in available_engines' clause.
        self.assertIn("piper_allowed", src)
        self.assertIn('piper_allowed = cli_fallback != "none"', src)

    def test_last_resort_recovery_honours_fallback_none(self):
        """`_last_resort_recovery` must keep the requested engine when
        --fallback-engine=none, instead of unconditionally upgrading to
        Piper."""
        src = inspect.getsource(_RetryMixin._last_resort_recovery)
        self.assertIn("_cli_fallback_engine", src)
        self.assertIn('cli_fallback == "none"', src)


if __name__ == "__main__":
    unittest.main()
