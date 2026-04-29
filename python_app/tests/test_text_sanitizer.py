"""Tests for the Edge-recovery text sanitiser and sentence splitter."""

from __future__ import annotations

from python_app.src.text_sanitizer import (
    sanitize_for_edge_recovery,
    split_into_sentences,
)


class TestSanitizeForEdgeRecovery:
    def test_strips_zero_width_joiners(self):
        # Word-internal ZWJ from copy-pasted EPUB text — must vanish.
        text = "fa\u200dmilia"
        assert sanitize_for_edge_recovery(text) == "familia"

    def test_strips_soft_hyphens(self):
        text = "co\u00admo\u00addity"
        assert "\u00ad" not in sanitize_for_edge_recovery(text)
        assert sanitize_for_edge_recovery(text) == "comodity"

    def test_strips_bom_in_middle(self):
        text = "Hello\ufeffworld"
        assert sanitize_for_edge_recovery(text) == "Helloworld"

    def test_strips_directional_marks(self):
        text = "left\u200eto\u200fright"
        assert "\u200e" not in sanitize_for_edge_recovery(text)
        assert "\u200f" not in sanitize_for_edge_recovery(text)

    def test_collapses_nbsp_to_space(self):
        text = "fim\u00a0do\u00a0capítulo"
        assert sanitize_for_edge_recovery(text) == "fim do capítulo"

    def test_normalises_decomposed_accents_to_precomposed(self):
        # NFKC composes "e + combining acute" into "é".
        decomposed = "e\u0301poca"
        result = sanitize_for_edge_recovery(decomposed)
        assert result == "época"
        assert "\u0301" not in result

    def test_preserves_normal_text(self):
        text = "Olá, mundo! Tudo bem?"
        assert sanitize_for_edge_recovery(text) == text

    def test_collapses_runs_of_spaces(self):
        text = "muito    espaco     aqui"
        assert sanitize_for_edge_recovery(text) == "muito espaco aqui"

    def test_empty_input_returns_empty(self):
        assert sanitize_for_edge_recovery("") == ""
        assert sanitize_for_edge_recovery("   \n\t  ") == ""

    def test_strips_control_chars_but_keeps_newlines(self):
        text = "linha um\nlinha dois\x00\x07tres"
        result = sanitize_for_edge_recovery(text)
        assert "\x00" not in result
        assert "\x07" not in result
        assert "\n" in result


class TestSplitIntoSentences:
    def test_splits_on_period_followed_by_capital(self):
        text = "Primeira frase. Segunda frase. Terceira."
        out = split_into_sentences(text)
        assert len(out) == 3
        assert out[0].endswith(".")

    def test_splits_on_question_and_exclamation(self):
        text = "Olá! Tudo bem? Sim, obrigado."
        out = split_into_sentences(text)
        assert len(out) == 3

    def test_does_not_split_inside_abbreviation(self):
        # Lowercase after period should NOT trigger a split.
        text = "etc. continuou a explicação."
        out = split_into_sentences(text)
        assert len(out) == 1

    def test_force_splits_oversized_sentence_on_comma(self):
        # 1500-char default — build a sentence with no period but commas.
        chunks = ["fragmento " + str(i) for i in range(200)]
        long_text = ", ".join(chunks) + "."
        assert len(long_text) > 1500
        out = split_into_sentences(long_text, max_chars=1500)
        assert all(len(s) <= 1500 for s in out)
        assert len(out) >= 2

    def test_force_splits_on_em_dash_when_no_commas(self):
        text = "primeiro " * 200 + " — " + "segundo " * 200
        out = split_into_sentences(text, max_chars=1000)
        assert all(len(s) <= 1000 for s in out)

    def test_falls_back_to_whitespace_split_for_no_punctuation(self):
        # Pathological: 2000 chars with no punctuation at all.
        text = ("palavra " * 300).strip()
        out = split_into_sentences(text, max_chars=500)
        assert len(out) >= 2
        assert all(len(s) <= 500 for s in out)
        # No word should be cut in half.
        for fragment in out:
            assert " " not in fragment[:1] and " " not in fragment[-1:]

    def test_empty_input_returns_empty_list(self):
        assert split_into_sentences("") == []
        assert split_into_sentences("   ") == []

    def test_single_short_sentence_returned_as_is(self):
        assert split_into_sentences("Olá.") == ["Olá."]
