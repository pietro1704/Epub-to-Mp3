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

import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(__file__))))

import validate_conversion as vc
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


def _validate_durations(lengths, durations, *, tolerance=None, env_tolerance=""):
    """Exercise public validation with local artifacts and a deterministic audio probe."""
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        output_dir = root / "output"
        text_dir = output_dir / "text"
        text_dir.mkdir(parents=True)
        cache_dir = root / "cache"
        cache_dir.mkdir()
        chapters = []
        for index, length in enumerate(lengths, 1):
            title = f"Chapter {index}"
            text = ("word " * (length // 5 + 1))[: length - 1] + "x"
            chapters.append((index, title, text))
            for suffix in ("parsed", "pre-tts"):
                (text_dir / f"{index} - {title}-{suffix}.txt").write_text(
                    text, encoding="utf-8"
                )
            # Distinct valid-looking payloads; no decoder, network or TTS is used.
            (output_dir / f"{index} - {title}.mp3").write_bytes(
                b"\xff\xfb" + bytes([index]) * 4096
            )
        (output_dir / "book_complete.txt").write_text(
            "\n".join(f"CHAPTER {label}: {title}\n{text}" for label, title, text in chapters),
            encoding="utf-8",
        )
        with (
            patch.dict(os.environ, {"VALIDATION_DURATION_TOLERANCE": env_tolerance}),
            patch("validate_conversion.AudioValidator") as validator_class,
            patch("validate_conversion.load_epub_chapters", return_value=chapters) as load,
            redirect_stdout(io.StringIO()),
        ):
            validator = validator_class.return_value
            validator.get_audio_duration.side_effect = lambda path: durations[
                int(path.name.split(" - ", 1)[0]) - 1
            ]
            validator.validate_duration.return_value = SimpleNamespace(
                is_valid=True, duration_diff_percent=0
            )
            result = vc.validate_book(
                root / "book.epub", output_dir, cache_dir, duration_tolerance=tolerance
            )
            load.assert_called_once_with(root / "book.epub")
        return result, validator


class TestEdgeTTSPtBRDurationTolerance(unittest.TestCase):
    """Observe the public validator's actual duration policy without real audio."""

    def test_short_chapter_tolerance_default_is_at_least_60_percent(self):
        for length, expected in ((5000, 0.70), (9999, 0.70), (10000, 0.60), (12000, 0.60)):
            with self.subTest(length=length):
                (stats, _), validator = _validate_durations([length], [300.0])
                self.assertEqual(stats["duration_mismatch"], 0)
                self.assertEqual(validator.validate_duration.call_count, 1)
                self.assertEqual(
                    validator.validate_duration.call_args.kwargs["tolerance"], expected
                )

    def test_env_var_override_still_clamped(self):
        cases = (("2.0", 0.95), ("0.01", 0.10), ("0.40", 0.40), ("invalid", 0.70), ("0", 0.70))
        for env, expected in cases:
            with self.subTest(env=env):
                _, validator = _validate_durations([5000], [300.0], env_tolerance=env)
                self.assertEqual(
                    validator.validate_duration.call_args.kwargs["tolerance"], expected
                )

    def test_explicit_override_takes_precedence_over_environment(self):
        _, validator = _validate_durations(
            [5000], [300.0], tolerance=0.25, env_tolerance="0.90"
        )
        self.assertEqual(validator.validate_duration.call_args.kwargs["tolerance"], 0.25)

    def test_book_median_accepts_healthy_duration_without_legacy_probe(self):
        (stats, _), validator = _validate_durations([6000] * 5, [720.0] * 5)
        self.assertEqual(stats["duration_mismatch"], 0)
        validator.validate_duration.assert_not_called()

    def test_book_median_flags_only_duration_outlier(self):
        (stats, issues), validator = _validate_durations(
            [6000] * 6, [720.0] * 5 + [2400.0]
        )
        self.assertEqual(stats["duration_mismatch"], 1)
        self.assertTrue(any("Chapter 6: Duration outlier" in issue for issue in issues))
        validator.validate_duration.assert_not_called()


if __name__ == "__main__":
    unittest.main()
