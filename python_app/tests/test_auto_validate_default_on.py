"""Pin the v0.3.14 default: auto-validate + auto-fix run after every conversion.

The user explicitly asked for "app precisa detectar erros e corrigir
automaticamente" after a Carl conversion missed chapter 7.20. The fix:
flip `auto_validate_output` from False to True so the post-conversion
`validate_book` step runs unconditionally and `_auto_validate_and_retry_async`
re-synthesises any chapter that comes back missing/short/broken.

Operators that need the legacy opt-in behaviour can still pass
`AUTO_VALIDATE_OUTPUT=0` or `auto_validate_output=False` explicitly.
"""

from __future__ import annotations

import os
import unittest
from unittest.mock import patch

from python_app.src.config import AppConfig, ConversionConfig


class TestAutoValidateDefaultOn(unittest.TestCase):
    def test_dataclass_default_is_true(self):
        cfg = ConversionConfig(engine="edge")
        self.assertTrue(cfg.auto_validate_output)
        self.assertTrue(cfg.auto_fix_output)

    def test_app_config_default_is_true(self):
        cfg = AppConfig().create_conversion_config(engine="edge")
        self.assertTrue(cfg.auto_validate_output)
        self.assertTrue(cfg.auto_fix_output)

    def test_explicit_kwarg_can_disable(self):
        cfg = AppConfig().create_conversion_config(engine="edge", auto_validate_output=False)
        self.assertFalse(cfg.auto_validate_output)

    def test_env_var_zero_disables(self):
        with patch.dict(os.environ, {"AUTO_VALIDATE_OUTPUT": "0"}):
            cfg = AppConfig().create_conversion_config(engine="edge")
        self.assertFalse(cfg.auto_validate_output)

    def test_env_var_false_disables(self):
        with patch.dict(os.environ, {"AUTO_VALIDATE_OUTPUT": "false"}):
            cfg = AppConfig().create_conversion_config(engine="edge")
        self.assertFalse(cfg.auto_validate_output)

    def test_env_var_off_disables(self):
        with patch.dict(os.environ, {"AUTO_VALIDATE_OUTPUT": "off"}):
            cfg = AppConfig().create_conversion_config(engine="edge")
        self.assertFalse(cfg.auto_validate_output)

    def test_env_var_one_keeps_default_on(self):
        with patch.dict(os.environ, {"AUTO_VALIDATE_OUTPUT": "1"}):
            cfg = AppConfig().create_conversion_config(engine="edge")
        self.assertTrue(cfg.auto_validate_output)

    def test_explicit_kwarg_overrides_env(self):
        """Explicit kwargs take precedence over the env var."""
        with patch.dict(os.environ, {"AUTO_VALIDATE_OUTPUT": "0"}):
            cfg = AppConfig().create_conversion_config(engine="edge", auto_validate_output=True)
        self.assertTrue(cfg.auto_validate_output)


if __name__ == "__main__":
    unittest.main()
