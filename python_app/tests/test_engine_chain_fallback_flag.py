# -*- coding: utf-8 -*-
"""Tests for ENGINE_CHAIN_FALLBACK gating in both CLI and server paths."""

import importlib
import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


class TestConverterModuleGate(unittest.TestCase):
    """The CLI path reads ENGINE_CHAIN_FALLBACK at import time."""

    def _reload_converter(self):
        import src.converter as converter

        return importlib.reload(converter)

    def test_default_is_false(self):
        env = dict(os.environ)
        env.pop("ENGINE_CHAIN_FALLBACK", None)
        with patch.dict(os.environ, env, clear=True):
            converter = self._reload_converter()
            self.assertFalse(converter.ENGINE_CHAIN_FALLBACK)

    def test_explicit_enable(self):
        with patch.dict(os.environ, {"ENGINE_CHAIN_FALLBACK": "1"}, clear=False):
            converter = self._reload_converter()
            self.assertTrue(converter.ENGINE_CHAIN_FALLBACK)

    def test_string_false_values_disabled(self):
        for value in ("0", "false", "no", ""):
            with patch.dict(os.environ, {"ENGINE_CHAIN_FALLBACK": value}, clear=False):
                converter = self._reload_converter()
                self.assertFalse(
                    converter.ENGINE_CHAIN_FALLBACK,
                    f"value={value!r} should be disabled",
                )

    @classmethod
    def tearDownClass(cls):
        # Restore the module to its natural environment so other tests see
        # the real default rather than whatever the last test-case set.
        import src.converter as converter

        importlib.reload(converter)


class TestCliFlagPresent(unittest.TestCase):
    def test_flag_parses(self):
        from main import create_argument_parser

        parser = create_argument_parser()
        args = parser.parse_args(["convert", "test.epub", "--engine-chain-fallback"])
        self.assertTrue(args.engine_chain_fallback)

    def test_flag_default_false(self):
        from main import create_argument_parser

        parser = create_argument_parser()
        args = parser.parse_args(["convert", "test.epub"])
        self.assertFalse(args.engine_chain_fallback)


if __name__ == "__main__":
    unittest.main()
