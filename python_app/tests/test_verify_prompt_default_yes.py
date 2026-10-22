"""Verification confirms by default and normalizes CR through the real CLI seam."""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from main import ConverterApplication
from src.ui.prompt import PromptResult, TerminalPrompt

import validate_conversion


@pytest.fixture
def verify_journey(tmp_path, monkeypatch):
    """Run only validation/prompt routing; no book parsing, synthesis or real terminal IO."""
    output = tmp_path / "Fixture"
    output.mkdir()
    input_path = tmp_path / "fixture.epub"
    input_path.write_bytes(b"source remains private and unchanged")
    config = SimpleNamespace(book_title="Fixture", output_dir=tmp_path, cache_dir=None)
    application = ConverterApplication.__new__(ConverterApplication)
    application.converter = SimpleNamespace(
        file_manager=SimpleNamespace(sanitize_filename=lambda title: title)
    )
    application._run_fix_mode = Mock(return_value=37)
    validate = Mock(return_value=({}, ["Chapter one needs repair"]))
    monkeypatch.setattr(validate_conversion, "validate_book", validate)
    read = Mock(return_value=PromptResult(""))
    monkeypatch.setattr(TerminalPrompt, "_read", read)
    bare_input = Mock(side_effect=AssertionError("The normal prompt must use TerminalPrompt"))
    monkeypatch.setattr("builtins.input", bare_input)
    return SimpleNamespace(
        application=application, path=input_path, config=config,
        validate=validate, read=read, bare_input=bare_input,
        run=lambda: application._run_verify_only(input_path, config, interactive=True),
    )


def test_prompt_label_changed_to_default_yes(verify_journey):
    verify_journey.read.return_value = PromptResult("n")
    assert verify_journey.run() == 1
    prompt = verify_journey.read.call_args.args[0]
    assert "Do you want to fix the issues now? [Y/n]" in prompt
    assert "[y/N]" not in prompt
    verify_journey.application._run_fix_mode.assert_not_called()


def test_empty_input_confirms(verify_journey):
    assert verify_journey.run() == 37
    verify_journey.application._run_fix_mode.assert_called_once_with(
        verify_journey.path, verify_journey.config
    )
    verify_journey.validate.assert_called_once_with(
        verify_journey.path, output_dir=verify_journey.config.output_dir / "Fixture", cache_dir=None
    )
    assert verify_journey.path.read_bytes() == b"source remains private and unchanged"


@pytest.mark.parametrize("answer", ["y\r", "YES\r", "\r", "s\r", "sim\r"])
def test_carriage_return_stripped_before_compare(verify_journey, answer):
    verify_journey.read.return_value = PromptResult(answer)
    assert verify_journey.run() == 37
    verify_journey.application._run_fix_mode.assert_called_once_with(
        verify_journey.path, verify_journey.config
    )


def test_verify_prompt_uses_terminal_prompt_not_bare_input(verify_journey):
    verify_journey.read.return_value = PromptResult("no\r")
    assert verify_journey.run() == 1
    verify_journey.read.assert_called_once()
    verify_journey.bare_input.assert_not_called()
    verify_journey.application._run_fix_mode.assert_not_called()
