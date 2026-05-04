"""Tests for --prewarm-kokoro CLI flag."""

from unittest.mock import patch

import python_app.main as main_module


class TestPrewarmKokoro:
    def test_skips_unsupported_language(self, capsys):
        result = main_module._prewarm_kokoro_pipeline("pt-BR")
        assert result is False
        captured = capsys.readouterr()
        assert "skipped" in captured.out.lower()

    def test_skips_unsupported_language_pt(self, capsys):
        assert main_module._prewarm_kokoro_pipeline("pt") is False

    def test_calls_ensure_kokoro_for_supported_language(self, capsys):
        with patch("src.tts.kokoro_engine._ensure_kokoro") as mock_ensure:
            mock_ensure.return_value = object()
            result = main_module._prewarm_kokoro_pipeline("en")
        assert result is True
        mock_ensure.assert_called_once()

    def test_returns_false_on_import_error(self):
        with patch(
            "src.tts.kokoro_engine._ensure_kokoro",
            side_effect=ImportError("no kokoro"),
        ):
            assert main_module._prewarm_kokoro_pipeline("en") is False

    def test_argparse_includes_flag(self):
        parser = main_module.create_argument_parser()
        # Parse with the flag — must not raise
        args = parser.parse_args(["convert", "fake.epub", "--prewarm-kokoro"])
        assert args.prewarm_kokoro is True

    def test_argparse_default_off(self):
        parser = main_module.create_argument_parser()
        args = parser.parse_args(["convert", "fake.epub"])
        assert args.prewarm_kokoro is False
