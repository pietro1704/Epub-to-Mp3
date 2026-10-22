"""Silence splicing preserves source/cleanup and facade probes without ffmpeg."""

import asyncio
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import pytest
from src import audio_postprocess as facade


@pytest.fixture
def splice_fixture(tmp_path, monkeypatch):
    audio = tmp_path / "chapter.mp3"
    original = b"original audio" * 20
    audio.write_bytes(original)
    work = tmp_path / "splice"
    work.mkdir()
    ensure = Mock()
    probe = Mock(return_value=22050)
    monkeypatch.setattr(facade, "_ensure_ffmpeg_paths", ensure)
    monkeypatch.setattr(facade, "_detect_audio_sample_rate", probe)
    monkeypatch.setattr(facade.tempfile, "mkdtemp", Mock(return_value=str(work)))
    return audio, original, work, ensure, probe


@pytest.mark.asyncio
async def test_splice_uses_facade_probe_and_commits_only_final_output(splice_fixture, monkeypatch):
    audio, _, work, ensure, probe = splice_fixture
    commands = []

    async def process(*command, **kwargs):
        commands.append(command)
        Path(command[-1]).write_bytes(b"new audio" * 30)
        return SimpleNamespace(returncode=0, wait=AsyncMock())

    monkeypatch.setattr(facade.asyncio, "create_subprocess_exec", process)
    assert await facade.inject_silence_at_offset(audio, insert_at_seconds=1.25) == (True, None)
    assert audio.read_bytes() == b"new audio" * 30
    ensure.assert_called_once_with()
    probe.assert_called_once_with(audio)
    assert "anullsrc=channel_layout=mono:sample_rate=22050" in commands[2]
    assert not work.exists()


@pytest.mark.asyncio
@pytest.mark.parametrize("cancel", [False, True])
async def test_splice_failure_or_cancellation_preserves_original_and_cleans_work(
    splice_fixture, monkeypatch, cancel
):
    audio, original, work, _, _ = splice_fixture
    calls = []

    async def process(*command, **kwargs):
        calls.append(command)
        if len(calls) == 2 and cancel:
            raise asyncio.CancelledError()
        return SimpleNamespace(returncode=1 if len(calls) == 2 else 0, wait=AsyncMock())

    monkeypatch.setattr(facade.asyncio, "create_subprocess_exec", process)
    if cancel:
        with pytest.raises(asyncio.CancelledError):
            await facade.inject_silence_at_offset(audio, insert_at_seconds=1.25)
    else:
        assert await facade.inject_silence_at_offset(audio, insert_at_seconds=1.25) == (
            False, "split tail failed"
        )
    assert audio.read_bytes() == original
    assert not work.exists()


@pytest.mark.asyncio
async def test_zero_pause_does_not_probe_or_launch_process(splice_fixture, monkeypatch):
    audio, original, _, ensure, probe = splice_fixture
    launch = AsyncMock()
    monkeypatch.setattr(facade.asyncio, "create_subprocess_exec", launch)
    assert await facade.inject_silence_at_offset(audio, insert_at_seconds=1.0, silence_ms=0) == (True, None)
    assert audio.read_bytes() == original
    ensure.assert_not_called()
    probe.assert_not_called()
    launch.assert_not_called()
