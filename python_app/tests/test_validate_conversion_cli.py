"""The validation CLI resolves its modules independently of the caller's directory."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class TestValidateConversionCli(unittest.TestCase):
    def _run_outside_checkout(self, *arguments):
        script = Path(__file__).resolve().parents[2] / "validate_conversion.py"
        environment = dict(os.environ)
        environment.pop("PYTHONPATH", None)
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [sys.executable, str(script), *arguments],
                cwd=temporary,
                env=environment,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(list(Path(temporary).iterdir()), [])
        return result

    def test_help_resolves_modules_outside_checkout(self):
        result = self._run_outside_checkout("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Validate EPUB → MP3 conversion integrity", result.stdout)
        self.assertIn("--output-dir", result.stdout)
        self.assertIn("--auto-fix", result.stdout)

    def test_missing_input_preserves_cli_failure_outside_checkout(self):
        result = self._run_outside_checkout("missing.epub")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("File not found: missing.epub", result.stdout)
        self.assertNotIn("Traceback", result.stderr)
