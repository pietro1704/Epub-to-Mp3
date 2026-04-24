# -*- coding: utf-8 -*-
"""Tests for audio_postprocess.add_silence_padding + config wiring."""

from __future__ import annotations

import asyncio
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from python_app.src.audio_postprocess import add_silence_padding
from python_app.src.config import AppConfig, ConversionConfig


@pytest.fixture
def dummy_mp3(tmp_path: Path) -> Path:
    path = tmp_path / "chapter.mp3"
    path.write_bytes(b"\xff\xfb" + b"\x00" * 512)  # fake MP3 header + filler > 100B
    return path


def _make_fake_proc(returncode: int = 0, stderr: bytes = b""):
    proc = AsyncMock()
    proc.communicate = AsyncMock(return_value=(b"", stderr))
    proc.returncode = returncode
    return proc


def test_noop_when_both_durations_zero(dummy_mp3: Path) -> None:
    ok, error = asyncio.run(add_silence_padding(dummy_mp3, intro_ms=0, outro_ms=0))
    assert ok is True
    assert error is None


def test_returns_false_for_missing_input(tmp_path: Path) -> None:
    missing = tmp_path / "ghost.mp3"
    ok, error = asyncio.run(add_silence_padding(missing, intro_ms=0, outro_ms=500))
    assert ok is False
    assert error is not None


def test_returns_false_for_too_small_input(tmp_path: Path) -> None:
    tiny = tmp_path / "tiny.mp3"
    tiny.write_bytes(b"\x00" * 50)
    ok, error = asyncio.run(add_silence_padding(tiny, intro_ms=0, outro_ms=500))
    assert ok is False
    assert "too small" in (error or "")


def test_invokes_ffmpeg_with_outro_filter(dummy_mp3: Path) -> None:
    original_bytes = dummy_mp3.read_bytes()

    captured: dict = {}

    async def fake_exec(cmd, **kwargs):
        captured["args"] = cmd
        output = Path(cmd[-1])
        output.write_bytes(b"\xff\xfb" + b"\x01" * 1024)
        return _make_fake_proc(returncode=0)

    with patch(
        "python_app.src.audio_postprocess.asyncio.create_subprocess_exec",
        side_effect=fake_exec,
    ):
        ok, error = asyncio.run(add_silence_padding(dummy_mp3, intro_ms=0, outro_ms=500))

    assert ok is True
    assert error is None
    args = captured["args"]
    assert "ffmpeg" in args
    # Primary path now uses concat-copy (no -af re-encoding)
    assert "-c" in args
    assert "copy" in args
    # Output file overwritten with padded data
    assert dummy_mp3.read_bytes() != original_bytes


def test_invokes_ffmpeg_with_intro_and_outro(dummy_mp3: Path) -> None:
    all_calls: list = []

    async def fake_exec(cmd, **kwargs):
        all_calls.append(cmd)
        Path(cmd[-1]).write_bytes(b"\xff\xfb" + b"\x01" * 1024)
        return _make_fake_proc(returncode=0)

    with patch(
        "python_app.src.audio_postprocess.asyncio.create_subprocess_exec",
        side_effect=fake_exec,
    ):
        ok, _ = asyncio.run(add_silence_padding(dummy_mp3, intro_ms=250, outro_ms=750))

    assert ok is True
    # Should have 3 calls: intro silence, outro silence, concat-copy
    assert len(all_calls) >= 2
    # Last call should be concat-copy
    concat_call = all_calls[-1]
    assert "-c" in concat_call
    assert "copy" in concat_call


def test_leaves_original_when_ffmpeg_fails(dummy_mp3: Path) -> None:
    original_bytes = dummy_mp3.read_bytes()

    async def fake_exec(cmd, **kwargs):
        return _make_fake_proc(returncode=1, stderr=b"ffmpeg: bad filter")

    with patch(
        "python_app.src.audio_postprocess.asyncio.create_subprocess_exec",
        side_effect=fake_exec,
    ):
        ok, error = asyncio.run(add_silence_padding(dummy_mp3, intro_ms=0, outro_ms=500))

    assert ok is False
    assert "bad filter" in (error or "")
    assert dummy_mp3.read_bytes() == original_bytes


def test_handles_missing_ffmpeg_binary(dummy_mp3: Path) -> None:
    async def fake_exec(cmd, **kwargs):
        raise FileNotFoundError("ffmpeg")

    with patch(
        "python_app.src.audio_postprocess.asyncio.create_subprocess_exec",
        side_effect=fake_exec,
    ):
        ok, error = asyncio.run(add_silence_padding(dummy_mp3, intro_ms=0, outro_ms=500))

    assert ok is False
    assert "ffmpeg binary not found" == error


def test_handles_negative_and_invalid_durations(dummy_mp3: Path) -> None:
    ok_neg, _ = asyncio.run(add_silence_padding(dummy_mp3, intro_ms=-100, outro_ms=-200))
    assert ok_neg is True  # normalised to 0 → noop

    ok_bad, err_bad = asyncio.run(
        add_silence_padding(dummy_mp3, intro_ms="abc", outro_ms=500)  # type: ignore[arg-type]
    )
    assert ok_bad is False
    assert err_bad == "invalid duration"


def test_config_default_silence_values() -> None:
    cfg = ConversionConfig(engine="edge")
    assert cfg.chapter_intro_silence_ms == 0
    assert cfg.chapter_outro_silence_ms == 500


def test_app_config_reads_silence_kwargs() -> None:
    provider = AppConfig()
    cfg = provider.create_conversion_config(
        engine="edge",
        chapter_intro_silence_ms=300,
        chapter_outro_silence_ms=1000,
    )
    assert cfg.chapter_intro_silence_ms == 300
    assert cfg.chapter_outro_silence_ms == 1000


def test_app_config_reads_silence_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CHAPTER_INTRO_SILENCE_MS", "200")
    monkeypatch.setenv("CHAPTER_OUTRO_SILENCE_MS", "900")
    cfg = AppConfig().create_conversion_config(engine="edge")
    assert cfg.chapter_intro_silence_ms == 200
    assert cfg.chapter_outro_silence_ms == 900


def test_app_config_clamps_negative_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CHAPTER_INTRO_SILENCE_MS", "-50")
    monkeypatch.setenv("CHAPTER_OUTRO_SILENCE_MS", "garbage")
    cfg = AppConfig().create_conversion_config(engine="edge")
    assert cfg.chapter_intro_silence_ms == 0
    assert cfg.chapter_outro_silence_ms == ConversionConfig.chapter_outro_silence_ms


def test_concat_fallback_succeeds_when_filter_step_fails(dummy_mp3: Path) -> None:
    """When the -af step fails (e.g. decode error), the concat fallback runs."""
    calls: list[tuple] = []

    async def fake_exec(cmd, **kwargs):
        calls.append(cmd)
        # First call is the filter step — fail it to trigger the fallback.
        if calls and len(calls) == 1:
            return _make_fake_proc(returncode=1, stderr=b"Decode error rate 1 exceeds maximum")
        # Silence / concat steps succeed and write something to the output path.
        Path(cmd[-1]).write_bytes(b"\xff\xfb" + b"\x02" * 1024)
        return _make_fake_proc(returncode=0)

    with patch(
        "python_app.src.audio_postprocess.asyncio.create_subprocess_exec",
        side_effect=fake_exec,
    ):
        ok, error = asyncio.run(add_silence_padding(dummy_mp3, intro_ms=100, outro_ms=500))

    assert ok is True, f"fallback should succeed, got error={error}"
    assert error is None
    cmds_joined = " ".join(" ".join(c) for c in calls)
    assert "anullsrc" in cmds_joined
    assert "concat" in cmds_joined


def test_concat_fallback_reports_error_when_both_paths_fail(dummy_mp3: Path) -> None:
    """If filter AND concat fallback fail, original error is surfaced."""

    async def fake_exec(cmd, **kwargs):
        return _make_fake_proc(returncode=1, stderr=b"ffmpeg: total failure")

    with patch(
        "python_app.src.audio_postprocess.asyncio.create_subprocess_exec",
        side_effect=fake_exec,
    ):
        ok, error = asyncio.run(add_silence_padding(dummy_mp3, intro_ms=0, outro_ms=500))

    assert ok is False
    assert "total failure" in (error or "")


def test_config_as_dict_includes_silence_fields() -> None:
    cfg = ConversionConfig(
        engine="edge",
        chapter_intro_silence_ms=100,
        chapter_outro_silence_ms=600,
    )
    data = cfg.as_dict()
    assert data["chapter_intro_silence_ms"] == 100
    assert data["chapter_outro_silence_ms"] == 600
