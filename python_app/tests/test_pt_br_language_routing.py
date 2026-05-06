# -*- coding: utf-8 -*-
"""Regression tests for the v0.3.24 fix: pt-BR text mis-routed to a
foreign Edge voice by the auto language detection chain.

Symptom (user report 2026-05-06): with Edge auto-detection ON, pt-BR
chapters were being narrated with a foreign accent because individual
paragraphs scored marginally higher on a Romance-language sibling
(es/it/ca) and ended up wrapped in ``[[lang:es]]`` markers, which then
routed the chunk to the Spanish Edge voice.

The fix is layered:
1. ``LanguageDetector.detect_segments`` refined-loop: do not allow the
   second-pass detection to flip a paragraph away from the primary
   language. Only foreign→primary corrections are honoured.
2. ``LanguageMarkup.annotate`` final confirmation: routes through
   ``_detect_language_with_timeout`` (with ``primary_language`` wired)
   instead of the bare ``_detect_language_simple`` so the ambiguity
   guardrail can reclaim borderline calls.
3. ``LanguageMarkup`` profile-level allow-mixed gate: raised the
   foreign-evidence floor from 0.35 to 0.45 and tightened the
   primary-prob comparison.
"""

from __future__ import annotations

from unittest.mock import patch

from src.language.detector import (
    LanguageDetector,
    LanguagePrediction,
    LanguageSegment,
)
from src.language.markup import LanguageMarkup


def _detector() -> LanguageDetector:
    det = LanguageDetector()
    det._detect_cache.clear()
    return det


def test_refined_loop_does_not_flip_primary_to_foreign():
    """First pass says pt; second pass flips to es. Guardrail must keep pt."""
    det = _detector()
    paragraph = "Este é um parágrafo longo em português brasileiro. " * 10

    # Stage the two passes: first call returns pt, second call returns es.
    calls = {"n": 0}

    def _fake(text, **kw):
        calls["n"] += 1
        return "pt" if calls["n"] == 1 else "es"

    with patch.object(det, "_detect_language_with_timeout", side_effect=_fake):
        segments = det.detect_segments(paragraph, primary_language="pt")
    assert segments
    # The primary-language stickiness rule must hold even when the
    # refined-pass detection contradicts the first pass.
    assert all(seg.language == "pt" for seg in segments)


def test_refined_loop_allows_foreign_to_primary_correction():
    """First pass mis-classifies a pt paragraph as es; second pass corrects to pt."""
    det = _detector()
    paragraph = "Este é um parágrafo longo em português brasileiro. " * 10
    calls = {"n": 0}

    def _fake(text, **kw):
        calls["n"] += 1
        return "es" if calls["n"] == 1 else "pt"

    with patch.object(det, "_detect_language_with_timeout", side_effect=_fake):
        segments = det.detect_segments(paragraph, primary_language="pt")
    # Foreign → primary correction is the *desirable* direction; honour it.
    assert segments[0].language == "pt"


def test_markup_uses_primary_language_in_final_confirmation():
    """``LanguageMarkup.annotate`` must propagate primary_language into
    the per-segment confirmation pass — otherwise borderline pt segments
    that langdetect happens to score es ≥ 0.8 get tagged as foreign.
    """
    det = _detector()
    markup = LanguageMarkup(detector=det)

    # Stage the detector path so the segment-level confirmation runs.
    # Profile passes the allow_mixed gate (alt_prob clearly dominates) so
    # the per-segment confirmation actually runs.
    profile = type(
        "P",
        (),
        {
            "primary": "pt",
            "languages": ["pt", "es"],
            "predictions": [
                LanguagePrediction(code="es", probability=0.78),
                LanguagePrediction(code="pt", probability=0.20),
            ],
            "analysed_chars": 800,
            "is_confident": True,
        },
    )()
    with (
        patch.object(det, "detect_profile", return_value=profile),
        patch.object(
            det,
            "detect_segments",
            return_value=[
                LanguageSegment(language="es", text="X" * 200),
            ],
        ),
        patch.object(det, "_detect_language_with_timeout") as mock_confirm,
        patch.object(det, "_detect_language_simple", return_value="es") as mock_simple,
    ):
        mock_confirm.return_value = "pt"  # ambiguity guardrail reclaims it
        out = markup.annotate("X" * 200, "pt", prioritize_primary_language=True)

    # The final confirmation must be the timeout-aware call (primary-aware),
    # not the bare ``_detect_language_simple`` that ignored the primary lang.
    assert mock_confirm.called
    # When the timeout-aware call returns the primary language, no
    # foreign-language tag should be emitted.
    assert "[[lang:es]]" not in out
    assert "[[lang:pt]]" not in out  # primary is implicit, never tagged


def test_markup_skips_marking_when_alt_evidence_weak():
    """Profile shows pt=0.50, es=0.40. Old gate (alt>=0.35) would allow
    mixed markup; tightened gate (alt>=0.45) must short-circuit."""
    det = _detector()
    markup = LanguageMarkup(detector=det)
    profile = type(
        "P",
        (),
        {
            "primary": "pt",
            "languages": ["pt", "es"],
            "predictions": [
                LanguagePrediction(code="pt", probability=0.50),
                LanguagePrediction(code="es", probability=0.40),
            ],
            "analysed_chars": 800,
            "is_confident": True,
        },
    )()

    # If the gate fires, detect_segments is not called. Monitor that.
    with (
        patch.object(det, "detect_profile", return_value=profile),
        patch.object(det, "detect_segments") as mock_segments,
    ):
        out = markup.annotate("Texto qualquer.", "pt")
    assert not mock_segments.called
    # Output must be unchanged plain text (no markup applied).
    assert "[[lang:" not in out
