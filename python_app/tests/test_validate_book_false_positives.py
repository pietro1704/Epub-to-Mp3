"""Regression: validate_book stopped flagging the v0.3.11 hash marker
and stopped over-rejecting Edge-TTS PT-BR durations.

These tests reproduce the exact false positives the user saw on the
2026-04-29 Carl, o Explorador de Masmorras run:

    Chapter 7.14 '... ainda tinha aguardente de sobra por isso donut e':
        MP3 filename '... visualiza [7ce6a4d41a].mp3' does not match EPUB heading
    Chapter 7.14: Duration mismatch (+53%)

Both came from valid audio with valid filenames. The validator was
applying rules that didn't account for (a) the SHA-1 marker we now
append on truncated names and (b) Edge-TTS PT-BR neural's measured WPM
(~100-130, vs the 150 the estimator assumes).
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(__file__))))

from validate_conversion import (
    _strip_hash_marker,
    normalize_title_key,
    normalized_file_title,
    titles_align,
)


class TestHashMarkerStripped:
    """`[7ce6a4d41a]` (or any 8-16 hex chars in brackets) must vanish
    before the validator compares filenames against EPUB headings."""

    def test_strip_hash_at_end_of_filename(self):
        assert _strip_hash_marker("foo bar [7ce6a4d41a]") == "foo bar"
        assert _strip_hash_marker("foo bar [9029832cba]") == "foo bar"

    def test_strip_hash_with_trailing_whitespace(self):
        assert _strip_hash_marker("foo bar [abcdef1234]  ") == "foo bar"

    def test_does_not_strip_hash_with_letters_outside_hex(self):
        # `[zzzz1234]` is not a valid hex string, leave it alone.
        assert _strip_hash_marker("foo [zzzz1234]") == "foo [zzzz1234]"

    def test_does_not_strip_too_short_or_too_long_brackets(self):
        # 7-char hex too short, 17-char too long — out of [8, 16] range.
        assert _strip_hash_marker("foo [1234567]") == "foo [1234567]"
        assert _strip_hash_marker("foo [12345678901234567]") == "foo [12345678901234567]"

    def test_normalize_filename_with_hash_matches_clean_title(self):
        """The exact failure scenario from the Carl 7.14 chapter."""
        mp3_name = (
            "7.14 - Parte dois - Capítulo 41 - _ tempo até o colapso do "
            "andar 4 dias 6 horas. visualiza [7ce6a4d41a].mp3"
        )
        mp3_norm = normalized_file_title(Path(mp3_name))
        # The hash marker must NOT appear in the normalised form.
        assert "7ce6a4d41a" not in mp3_norm
        # The chapter title from the EPUB:
        epub_title = "Capítulo 41"
        title_norm = normalize_title_key(epub_title)
        assert titles_align(title_norm, mp3_norm)


class TestEdgeTTSPtBRDurationTolerance(unittest.TestCase):
    """The validator's default duration tolerance now allows Edge-TTS
    PT-BR's slower neural voices without flagging healthy audio.

    We don't drive `validate_book` end-to-end (heavy fixtures) — we just
    pin the new default constants the validator uses so a future tweak
    that lowers them below what Edge-TTS PT-BR actually achieves
    breaks CI.
    """

    def test_short_chapter_tolerance_default_is_at_least_60_percent(self):
        from validate_conversion import (
            validate_book as _v,  # noqa: F401  ensure module imports
        )

        # The default branch in validate_book reads:
        #   tolerance = 0.70 if pretts_len < 10000 else 0.60
        # — pin both. If someone tightens these without thinking about
        # the Edge-TTS PT-BR speed range we'll catch it here.
        text = open(__file__, encoding="utf-8").read()
        assert "tolerance = 0.70 if pretts_len < 10000 else 0.60" in (
            Path(__file__).resolve().parents[2] / "validate_conversion.py"
        ).read_text(encoding="utf-8")

    def test_env_var_override_still_clamped(self):
        from validate_conversion import _strip_hash_marker  # noqa: F401

        # If VALIDATION_DURATION_TOLERANCE is set to e.g. 2.0, the code
        # clamps to [0.10, 0.95]. Read the source as a smoke test.
        src = (Path(__file__).resolve().parents[2] / "validate_conversion.py").read_text(
            encoding="utf-8"
        )
        assert "max(0.10, min(env_tol, 0.95))" in src


if __name__ == "__main__":
    unittest.main()
