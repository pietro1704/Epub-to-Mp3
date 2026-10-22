"""Formatting extraction retains lexical fidelity, class binding and cue literals."""

import asyncio
from unittest.mock import Mock

import pytest
from src.text_formatting import FormattingSegment, TextFormattingProcessor


def test_markdown_cleanup_preserves_accents_paragraphs_and_dialogue():
    source = "**Olá**\n\n— _fala_"
    assert TextFormattingProcessor.strip_inline_markdown(source) == "Olá\n\n— fala"
    marked = "[[fmt:bold]]Olá[[/fmt]]\n\n— fala"
    assert TextFormattingProcessor.clean_tts_text(marked) == "Olá\n\n— fala"


def test_inherited_cleanup_remains_bound_to_the_public_subclass():
    class CustomFormatting(TextFormattingProcessor):
        @classmethod
        def remove_formatting_markers(cls, text):
            return "**custom**"

    assert CustomFormatting.strip_inline_markdown("ignored") == "custom"
    assert TextFormattingProcessor.strip_inline_markdown("unchanged") == "unchanged"


@pytest.mark.parametrize("error", [ValueError("cleanup failed"), asyncio.CancelledError()])
def test_cleanup_hook_failure_and_cancellation_propagate(error, monkeypatch):
    replacement = Mock(side_effect=error)
    monkeypatch.setattr(TextFormattingProcessor, "remove_formatting_markers", replacement)
    with pytest.raises(type(error)):
        TextFormattingProcessor.strip_inline_markdown("text")
    replacement.assert_called_once_with("text")


def test_language_markup_ignores_structural_language_and_preserves_content_language():
    formatter = TextFormattingProcessor()
    source = '<html lang="pt"><p lang="en">Hello &amp; welcome</p></html>'
    assert formatter._extract_language_attributes(source) == (
        "<html><p>[[lang:en]]Hello &amp; welcome[[/lang]]</p></html>"
    )


def test_portuguese_and_english_cues_remain_literal_after_cleanup_extraction():
    segment = FormattingSegment("texto", "italic")
    assert TextFormattingProcessor(cue_locale="pt-BR").to_plain_text_with_cues([segment]) == (
        "em itálico: texto fim do itálico."
    )
    assert TextFormattingProcessor(cue_locale="en").to_plain_text_with_cues([segment]) == (
        "italic text: texto end italic."
    )
