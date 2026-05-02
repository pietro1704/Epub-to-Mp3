"""CLI defaults must NOT silently fall through to Piper.

Carl regression cluster: every wrong-language audio bug came from
some retry/fallback path silently switching to Piper. The user
"verbose" run today had `--engine auto` without `--fallback-engine
none`, and the legacy default `--fallback-engine auto` would fall
through to Piper for any pt-BR sentence Edge timed out on.

These tests pin the safer defaults: `--fallback-engine` defaults to
`none`, so a user has to opt INTO Piper fallback explicitly.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


class TestCliDefaultsAreStrict(unittest.TestCase):
    def test_fallback_engine_default_is_none(self):
        """No silent Piper switch out of the box."""
        from main import create_argument_parser

        parser = create_argument_parser()
        ns = parser.parse_args(["convert", "x.epub"])
        self.assertEqual(getattr(ns, "fallback_engine", None), "none")

    def test_engine_default_is_edge(self):
        from main import create_argument_parser

        parser = create_argument_parser()
        ns = parser.parse_args(["convert", "x.epub"])
        self.assertEqual(getattr(ns, "engine", None), "edge")

    def test_engine_chain_fallback_default_is_off(self):
        from main import create_argument_parser

        parser = create_argument_parser()
        ns = parser.parse_args(["convert", "x.epub"])
        self.assertFalse(getattr(ns, "engine_chain_fallback", True))


if __name__ == "__main__":
    unittest.main()
