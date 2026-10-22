"""Piper extraction preserves facade patches, retry/cancellation and chunk isolation."""

import asyncio
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import pytest
from src.tts import piper_engine as facade


def _engine(tmp_path):
    model = tmp_path / "model.onnx"
    model.write_bytes(b"fixture model")
    return facade.PiperTTSEngine(model, max_procs=1), model


@pytest.mark.asyncio
async def test_single_process_retries_with_facade_binary_and_model_identity(tmp_path, monkeypatch):
    engine, model = _engine(tmp_path)
    output = tmp_path / "output.wav"
    binary = Mock(return_value="fixture-piper")
    monkeypatch.setattr(facade, "_find_piper_binary", binary)
    monkeypatch.setenv("PIPER_CHUNK_STALL_SECONDS", "0")
    monkeypatch.setenv("PIPER_CHUNK_MAX_RETRIES", "1")
    commands = []

    async def launch(*command, **kwargs):
        commands.append(command)
        code = 1 if len(commands) == 1 else 0

        async def communicate(input):
            assert input == b"speech payload"
            if code == 0:
                output.write_bytes(b"RIFF fixture")

        return SimpleNamespace(returncode=code, communicate=communicate)

    monkeypatch.setattr(facade.asyncio, "create_subprocess_exec", launch)
    assert await engine._synthesize_single("speech payload", output, model) == output
    assert len(commands) == 2
    assert all(command == ("fixture-piper", "--model", str(model), "--output_file", str(output)) for command in commands)
    binary.assert_called_once_with()
    assert model.read_bytes() == b"fixture model"


@pytest.mark.asyncio
async def test_single_process_cancellation_propagates(tmp_path, monkeypatch):
    engine, model = _engine(tmp_path)
    monkeypatch.setattr(facade, "_find_piper_binary", Mock(return_value="fixture-piper"))
    monkeypatch.setenv("PIPER_CHUNK_STALL_SECONDS", "0")
    process = SimpleNamespace(returncode=0, communicate=AsyncMock(side_effect=asyncio.CancelledError))
    monkeypatch.setattr(facade.asyncio, "create_subprocess_exec", AsyncMock(return_value=process))
    with pytest.raises(asyncio.CancelledError):
        await engine._synthesize_single("payload", tmp_path / "output.wav", model)


@pytest.mark.asyncio
async def test_parallel_chapters_keep_chunk_artifacts_isolated_and_cleaned(tmp_path, monkeypatch):
    engine, model = _engine(tmp_path)
    monkeypatch.setattr(facade, "_split_text_into_chunks", lambda text, _: [text + " A", text + " B"])
    monkeypatch.setattr(facade, "_merge_small_chunks", lambda chunks, *_, **__: chunks)
    monkeypatch.setattr(facade.shutil, "which", Mock(return_value="fixture-ffmpeg"))
    folders = []
    create_folder = facade.tempfile.mkdtemp

    def folder(*args, **kwargs):
        path = create_folder(*args, dir=tmp_path, **kwargs)
        folders.append(Path(path))
        return path

    monkeypatch.setattr(facade.tempfile, "mkdtemp", folder)

    async def single(text, path, actual_model):
        assert actual_model is model
        path.write_bytes(text.encode())
        return path

    async def concat(*command, **kwargs):
        manifest = Path(command[command.index("-i") + 1])
        chunks = [Path(line.split("'")[1]) for line in manifest.read_text().splitlines()]
        Path(command[-1]).write_bytes(b"".join(chunk.read_bytes() for chunk in chunks))
        return SimpleNamespace(returncode=0, wait=AsyncMock(return_value=0))

    monkeypatch.setattr(engine, "_synthesize_single", single)
    monkeypatch.setattr(facade.asyncio, "create_subprocess_exec", concat)
    first, second = tmp_path / "first.wav", tmp_path / "second.wav"
    results = await asyncio.gather(
        engine._synthesize_chunked("first", first, model),
        engine._synthesize_chunked("second", second, model),
    )
    assert results == [first, second]
    assert first.read_bytes() == b"first Afirst B"
    assert second.read_bytes() == b"second Asecond B"
    assert len(folders) == 2 and folders[0] != folders[1]
    assert all(not path.exists() for path in folders)
