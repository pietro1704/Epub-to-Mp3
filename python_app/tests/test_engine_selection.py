# -*- coding: utf-8 -*-
"""Unit tests for _engine_selection_mixin module-level helpers and mixin methods."""

import io
import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src._engine_selection_mixin import (
    _EngineSelectionMixin,
    _piper_fallback_disabled,
)


class _MinimalMixin(_EngineSelectionMixin):
    """Minimal concrete class that satisfies _EngineSelectionMixin method calls."""

    verbose = False

    def _resolve_offline_fallback_engine(self, available=None):
        # Delegate to the mixin method directly
        return _EngineSelectionMixin._resolve_offline_fallback_engine(self, available)


def _make_mixin() -> _MinimalMixin:
    return _MinimalMixin()


class TestPiperFallbackMonitoring(unittest.TestCase):
    """Tests for Piper fallback env-var guard and offline engine resolution."""

    # ------------------------------------------------------------------
    # _piper_fallback_disabled (module-level function)
    # ------------------------------------------------------------------

    def test_disabled_when_env_var_is_1(self):
        with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "1"}):
            self.assertTrue(_piper_fallback_disabled())

    def test_disabled_when_env_var_is_true(self):
        with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "true"}):
            self.assertTrue(_piper_fallback_disabled())

    def test_disabled_when_env_var_is_yes(self):
        with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "yes"}):
            self.assertTrue(_piper_fallback_disabled())

    def test_disabled_when_env_var_is_true_uppercase(self):
        """Value comparison is case-insensitive."""
        with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "TRUE"}):
            self.assertTrue(_piper_fallback_disabled())

    def test_disabled_when_env_var_is_yes_uppercase(self):
        with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "YES"}):
            self.assertTrue(_piper_fallback_disabled())

    def test_not_disabled_when_env_var_is_absent(self):
        env = {k: v for k, v in os.environ.items() if k != "DISABLE_PIPER_FALLBACK"}
        with patch.dict(os.environ, env, clear=True):
            self.assertFalse(_piper_fallback_disabled())

    def test_not_disabled_when_env_var_is_empty_string(self):
        with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": ""}):
            self.assertFalse(_piper_fallback_disabled())

    def test_not_disabled_when_env_var_is_0(self):
        with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "0"}):
            self.assertFalse(_piper_fallback_disabled())

    def test_not_disabled_when_env_var_is_false(self):
        with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "false"}):
            self.assertFalse(_piper_fallback_disabled())

    def test_not_disabled_when_env_var_is_no(self):
        with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "no"}):
            self.assertFalse(_piper_fallback_disabled())

    # ------------------------------------------------------------------
    # _resolve_offline_fallback_engine — piper disabled path
    # ------------------------------------------------------------------

    def test_returns_none_when_piper_disabled_via_env(self):
        """_resolve_offline_fallback_engine returns None when DISABLE_PIPER_FALLBACK=1."""
        mixin = _make_mixin()
        with (
            patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "1"}),
            patch("src._engine_selection_mixin._has_piper_support", return_value=True),
            patch("src._engine_selection_mixin._has_coqui_support", return_value=False),
        ):
            result = mixin._resolve_offline_fallback_engine()
        self.assertIsNone(result)

    def test_prints_disable_message_when_piper_skipped(self):
        """A human-readable message is printed when Piper is skipped via env var."""
        mixin = _make_mixin()
        with (
            patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "1"}),
            patch("src._engine_selection_mixin._has_piper_support", return_value=True),
            patch("src._engine_selection_mixin._has_coqui_support", return_value=False),
        ):
            captured = io.StringIO()
            with patch("sys.stdout", captured):
                mixin._resolve_offline_fallback_engine()
            output = captured.getvalue()
        self.assertIn("DISABLE_PIPER_FALLBACK", output)

    # ------------------------------------------------------------------
    # _resolve_offline_fallback_engine — piper available path
    # ------------------------------------------------------------------

    def test_returns_piper_when_piper_available_and_not_disabled(self):
        """Returns 'piper' when Piper is available and DISABLE_PIPER_FALLBACK is not set."""
        mixin = _make_mixin()
        env = {k: v for k, v in os.environ.items() if k != "DISABLE_PIPER_FALLBACK"}
        with (
            patch.dict(os.environ, env, clear=True),
            patch("src._engine_selection_mixin._has_piper_support", return_value=True),
            patch("src._engine_selection_mixin._has_coqui_support", return_value=False),
        ):
            result = mixin._resolve_offline_fallback_engine()
        self.assertEqual(result, "piper")

    def test_prints_piper_warning_when_piper_used(self):
        """A warning is printed to stdout when falling back to Piper."""
        mixin = _make_mixin()
        env = {k: v for k, v in os.environ.items() if k != "DISABLE_PIPER_FALLBACK"}
        with (
            patch.dict(os.environ, env, clear=True),
            patch("src._engine_selection_mixin._has_piper_support", return_value=True),
            patch("src._engine_selection_mixin._has_coqui_support", return_value=False),
        ):
            captured = io.StringIO()
            with patch("sys.stdout", captured):
                mixin._resolve_offline_fallback_engine()
            output = captured.getvalue()
        self.assertIn("PIPER", output.upper())

    # ------------------------------------------------------------------
    # _resolve_offline_fallback_engine — piper unavailable path
    # ------------------------------------------------------------------

    def test_returns_none_when_piper_unavailable_and_coqui_unavailable(self):
        """Returns None when neither Piper nor Coqui is available."""
        mixin = _make_mixin()
        with (
            patch("src._engine_selection_mixin._has_piper_support", return_value=False),
            patch("src._engine_selection_mixin._has_coqui_support", return_value=False),
        ):
            result = mixin._resolve_offline_fallback_engine()
        self.assertIsNone(result)


class TestCliFallbackEngineOverride(unittest.TestCase):
    """--fallback-engine CLI flag overrides default resolution."""

    def test_cli_override_none_returns_none_even_if_piper_available(self):
        mixin = _make_mixin()
        mixin._cli_fallback_engine = "none"
        with (
            patch("src._engine_selection_mixin._has_piper_support", return_value=True),
            patch("src._engine_selection_mixin._has_coqui_support", return_value=True),
        ):
            self.assertIsNone(mixin._resolve_offline_fallback_engine())

    def test_cli_override_kokoro_returns_kokoro(self):
        mixin = _make_mixin()
        mixin._cli_fallback_engine = "kokoro"
        with patch("src._engine_selection_mixin._has_piper_support", return_value=True):
            self.assertEqual(mixin._resolve_offline_fallback_engine(), "kokoro")

    def test_cli_override_piper_honored(self):
        mixin = _make_mixin()
        mixin._cli_fallback_engine = "piper"
        env = {k: v for k, v in os.environ.items() if k != "DISABLE_PIPER_FALLBACK"}
        with (
            patch.dict(os.environ, env, clear=True),
            patch("src._engine_selection_mixin._has_piper_support", return_value=True),
        ):
            self.assertEqual(mixin._resolve_offline_fallback_engine(), "piper")

    def test_cli_override_falls_through_when_unavailable(self):
        """If the override engine isn't available, default resolution still runs."""
        mixin = _make_mixin()
        mixin._cli_fallback_engine = "kokoro"  # not in available set
        with (
            patch("src._engine_selection_mixin._has_piper_support", return_value=True),
        ):
            result = mixin._resolve_offline_fallback_engine(available={"piper"})
        self.assertEqual(result, "piper")


if __name__ == "__main__":
    unittest.main()
