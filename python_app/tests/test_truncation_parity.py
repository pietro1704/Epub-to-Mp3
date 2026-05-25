"""Dual-path truncation-detection parity.

The CLI conversion path (`AudioConverter._convert_chapters_parallel` in
`converter.py`) and the server conversion path
(`_detect_short_audio_output` in `_server_audio_helpers.py`) must NEVER
disagree on whether a given (coverage, length, engine) triple counts
as truncated audio.

Why this matters: a chapter that just edges below the strict 90%
TRUNCATION_THRESHOLD bar but covers ≥ LENIENT_COVERAGE_THRESHOLD_PERCENT
(82% of text) used to be accepted by the CLI yet rejected + retried
by the server. The result was wasted Edge-TTS quota and user-visible
"converted in CLI, still spinning in web UI" divergence.

These tests pin the contract so a future refactor of either path
breaks CI instead of silently bringing the gap back.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

from python_app.src import _server_audio_helpers
from python_app.src.converter import (
    LENIENT_COVERAGE_THRESHOLD_PERCENT,
    TRUNCATION_THRESHOLD_PERCENT,
)


def test_lenient_threshold_constant_exists_and_is_lenient():
    """The lenient floor must be strictly below 100 - TRUNCATION_THRESHOLD."""
    strict_pass_floor = 100.0 - TRUNCATION_THRESHOLD_PERCENT  # default: 90.0
    assert LENIENT_COVERAGE_THRESHOLD_PERCENT < strict_pass_floor, (
        "LENIENT_COVERAGE_THRESHOLD_PERCENT must be lower than the strict "
        "validate_audio_completeness floor — otherwise the lenient branch "
        "is unreachable and the constant is dead code."
    )
    assert LENIENT_COVERAGE_THRESHOLD_PERCENT > 0, (
        "Lenient floor must be positive — anything else accepts truncated " "audio unconditionally."
    )


def _fake_audio(tmp_path: Path) -> Path:
    f = tmp_path / "ch.mp3"
    f.write_bytes(b"\xff\xfb\x90\x00" * 64)
    return f


def test_server_path_accepts_audio_at_or_above_lenient_threshold(tmp_path, monkeypatch):
    """82% coverage (above 80 lenient floor) must NOT trigger retry."""
    audio = _fake_audio(tmp_path)
    text = "x" * 10_000  # large enough to bypass the short-chapter cutoff

    with patch(
        "src.converter.validate_audio_completeness",
        return_value=(False, 82.0),
    ):
        warning = _server_audio_helpers._detect_short_audio_output(
            text=text,
            audio_path=audio,
            engine_label="edge",
        )

    assert warning is None, (
        f"Server path must accept ≥{LENIENT_COVERAGE_THRESHOLD_PERCENT}% "
        "coverage — keeps parity with the CLI's lenient acceptance and "
        "avoids retry loops on Edge-TTS WPM variance."
    )


def test_server_path_rejects_audio_below_lenient_threshold(tmp_path, monkeypatch):
    """70% coverage (below 80 floor) must still produce a truncation warning."""
    audio = _fake_audio(tmp_path)
    text = "x" * 10_000

    with patch(
        "src.converter.validate_audio_completeness",
        return_value=(False, 70.0),
    ):
        warning = _server_audio_helpers._detect_short_audio_output(
            text=text,
            audio_path=audio,
            engine_label="edge",
        )

    assert warning is not None
    assert "70" in warning, warning
    assert "truncated" in warning.lower()


def test_server_path_accepts_audio_that_strict_validator_already_passed(tmp_path, monkeypatch):
    """When the strict validator returns is_complete=True, the lenient branch must NOT alter it."""
    audio = _fake_audio(tmp_path)
    text = "x" * 10_000

    with patch(
        "src.converter.validate_audio_completeness",
        return_value=(True, 95.0),
    ):
        warning = _server_audio_helpers._detect_short_audio_output(
            text=text,
            audio_path=audio,
            engine_label="edge",
        )

    assert warning is None


def test_server_path_skips_validation_for_non_edge_engines(tmp_path):
    """Piper / Kokoro chapters never run truncation detection — both CLI
    and server skip them. Pinned because adding it later would mean a
    huge retry storm for offline runs that already produced full audio.
    """
    audio = _fake_audio(tmp_path)
    text = "x" * 10_000

    warning = _server_audio_helpers._detect_short_audio_output(
        text=text,
        audio_path=audio,
        engine_label="piper",
    )
    assert warning is None


@pytest.mark.parametrize(
    "coverage,expect_warning",
    [
        (100.0, False),
        (95.0, False),
        # Exactly at the lenient floor — must be accepted (>=).
        (LENIENT_COVERAGE_THRESHOLD_PERCENT, False),
        # Just below the floor.
        (LENIENT_COVERAGE_THRESHOLD_PERCENT - 1.0, True),
        (40.0, True),
    ],
)
def test_server_path_coverage_boundaries(tmp_path, coverage, expect_warning):
    """Parameterised sweep of the acceptance band so the boundary is pinned
    explicitly — both edges of LENIENT_COVERAGE_THRESHOLD_PERCENT covered."""
    audio = _fake_audio(tmp_path)
    text = "x" * 10_000

    # `is_complete` flag comes from validate_audio_completeness which
    # checks coverage_percent against the strict floor; we feed both
    # consistently here so the lenient branch is what's under test.
    strict_pass = (100.0 - coverage) <= TRUNCATION_THRESHOLD_PERCENT

    with patch(
        "src.converter.validate_audio_completeness",
        return_value=(strict_pass, coverage),
    ):
        warning = _server_audio_helpers._detect_short_audio_output(
            text=text,
            audio_path=audio,
            engine_label="edge",
        )

    if expect_warning:
        assert warning is not None, f"Coverage {coverage}% must trigger a truncation warning."
    else:
        assert warning is None, f"Coverage {coverage}% must be accepted; got warning: {warning}"
