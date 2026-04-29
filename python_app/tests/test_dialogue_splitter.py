"""Tests for the dialogue splitter — narrator vs character span routing."""

from __future__ import annotations

from python_app.src.dialogue_splitter import (
    DialogueSpan,
    split_into_dialogue_spans,
)


def _roles(text: str) -> list[str]:
    return [span.role for span in split_into_dialogue_spans(text)]


class TestQuotedDialogue:
    def test_curly_double_quotes_route_to_character(self):
        text = "Ele se levantou. \u201cBom dia\u201d, disse o capit\u00e3o."
        spans = split_into_dialogue_spans(text)
        roles = [s.role for s in spans]
        assert "character" in roles
        assert "narrator" in roles
        # The character span should not include the quote glyphs themselves.
        char_span = next(s for s in spans if s.role == "character")
        assert "\u201c" not in char_span.text
        assert "\u201d" not in char_span.text
        assert "Bom dia" in char_span.text

    def test_straight_double_quotes_also_split(self):
        text = 'She paused. "Hello there," she said.'
        roles = _roles(text)
        assert "character" in roles
        assert "narrator" in roles

    def test_french_angle_quotes_split(self):
        text = "Il regarda. \u00abBonjour\u00bb, dit-il."
        roles = _roles(text)
        assert "character" in roles

    def test_unbalanced_quote_falls_back_to_narrator(self):
        text = "Ele disse \u201col\u00e1 sem fechar"
        spans = split_into_dialogue_spans(text)
        # No half-open character span; the orphan tail stays narrator so we
        # don't synthesise a never-closing quoted block.
        assert all(s.role == "narrator" for s in spans)
        assert spans[-1].text.strip().endswith("sem fechar")


class TestEmDashLines:
    def test_em_dash_at_line_start_is_character(self):
        text = "Eles entraram na sala.\n\u2014 Ol\u00e1, todos!\nEla acenou."
        spans = split_into_dialogue_spans(text)
        roles = [s.role for s in spans]
        assert roles[0] == "narrator"
        assert "character" in roles
        char_span = next(s for s in spans if s.role == "character")
        assert "Ol\u00e1, todos" in char_span.text

    def test_en_dash_also_recognised(self):
        text = "Sala silenciosa.\n\u2013 Quem est\u00e1 a\u00ed?"
        roles = _roles(text)
        assert "character" in roles

    def test_em_dash_mid_line_is_not_dialogue(self):
        # An em-dash inside a sentence (parenthetical) must not flip voice.
        text = "Foi r\u00e1pido \u2014 muito r\u00e1pido \u2014 e acabou."
        roles = _roles(text)
        assert all(r == "narrator" for r in roles)


class TestCoalescing:
    def test_adjacent_narrator_spans_merge(self):
        text = "Primeiro par\u00e1grafo.\n\nSegundo par\u00e1grafo."
        spans = split_into_dialogue_spans(text)
        assert len(spans) == 1
        assert spans[0].role == "narrator"

    def test_empty_string_returns_empty_list(self):
        assert split_into_dialogue_spans("") == []

    def test_only_whitespace_returns_empty_list(self):
        assert split_into_dialogue_spans("   \n\n  ") == []


class TestEdgeCases:
    def test_only_dialogue_returns_only_character(self):
        text = "\u201cTudo bem\u201d"
        spans = split_into_dialogue_spans(text)
        assert len(spans) == 1
        assert spans[0].role == "character"

    def test_only_narration_returns_only_narrator(self):
        text = "Ele caminhou pela praia ao entardecer."
        spans = split_into_dialogue_spans(text)
        assert len(spans) == 1
        assert spans[0].role == "narrator"

    def test_returns_dialogue_span_dataclass(self):
        text = "\u201cOi\u201d"
        spans = split_into_dialogue_spans(text)
        assert isinstance(spans[0], DialogueSpan)
        assert spans[0].role in ("narrator", "character")
