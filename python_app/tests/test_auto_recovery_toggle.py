# -*- coding: utf-8 -*-
"""Regression: AutoRecovery must respect the DISABLE_AUTO_RECOVERY env var.

Without this guard, AutoRecovery interprets the sidecar's idle thread-
pool workers as "stuck" and raises KeyboardInterrupt in them. The
desktop binary therefore needs an opt-out — `python_app/server.py`
checks the env var inside the FastAPI lifespan and skips the
`start_auto_recovery()` call when set.

These tests don't run the full lifespan (it owns the global event
loop, the job queue, and a half-dozen side-effect tasks). Instead
they reproduce the exact branch and verify the call wiring.
"""

import os
import unittest
from unittest.mock import patch


class TestAutoRecoveryToggle(unittest.TestCase):
    def _branch(self) -> bool:
        """Mirror the server.py condition. Kept in sync with the
        lifespan code; if the env-var name or accepted values change,
        this helper changes too — which is exactly what we want."""
        return os.environ.get("DISABLE_AUTO_RECOVERY", "").lower() in {
            "1",
            "true",
            "yes",
            "on",
        }

    def test_branch_skips_when_set_to_one(self):
        with patch.dict(os.environ, {"DISABLE_AUTO_RECOVERY": "1"}, clear=False):
            self.assertTrue(self._branch())

    def test_branch_skips_for_truthy_strings(self):
        for value in ["true", "TRUE", "yes", "ON"]:
            with patch.dict(os.environ, {"DISABLE_AUTO_RECOVERY": value}, clear=False):
                self.assertTrue(self._branch(), f"value={value!r} should disable")

    def test_branch_does_not_skip_when_unset(self):
        # Same condition the server.py uses — empty string is falsy.
        env = dict(os.environ)
        env.pop("DISABLE_AUTO_RECOVERY", None)
        with patch.dict(os.environ, env, clear=True):
            self.assertFalse(self._branch())

    def test_branch_does_not_skip_for_falsy_values(self):
        for value in ["0", "false", "no", ""]:
            with patch.dict(os.environ, {"DISABLE_AUTO_RECOVERY": value}, clear=False):
                self.assertFalse(self._branch(), f"value={value!r} must NOT disable")

    def test_server_module_uses_same_truthy_set(self):
        """Snapshot test against `server.py` source so a refactor that
        accidentally narrows the truthy set surfaces here."""
        import inspect

        from python_app import server

        src = inspect.getsource(server._lifespan)
        # The exact string we expect — if someone edits the lifespan
        # to use a different env name, this test fails loudly.
        self.assertIn("DISABLE_AUTO_RECOVERY", src)
        self.assertIn('{"1", "true", "yes", "on"}', src)


if __name__ == "__main__":
    unittest.main()
