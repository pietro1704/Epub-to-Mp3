"""Nested synthesis callbacks retain their own engine, path and keyword scope."""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from python_app.src.sequential_conversion_state import SequentialConversionState
from python_app.src.sequential_session_preparation import _sequential_session_preparation


async def prepare_synthesizer(tmp_path):
    class StopAfterBinding(Exception):
        pass

    converter = SimpleNamespace(
        verbose=False, _filter_chapters_auto=Mock(side_effect=StopAfterBinding)
    )
    session = SequentialConversionState(
        chapters=[object()], engine_pool=SimpleNamespace(acquire=Mock()), output_dir=tmp_path,
        config=SimpleNamespace(engine="piper", extra={}), skip_preprocessing=False,
        is_auto_engine=False, auto_engine_pool={}, book_title="Book", book_author=None, cover_art=None,
    )
    with pytest.raises(StopAfterBinding):
        await _sequential_session_preparation(converter, session)
    return session


@pytest.mark.asyncio
async def test_interleaved_nested_invocations_do_not_borrow_sequential_loop_bindings(tmp_path):
    session = await prepare_synthesizer(tmp_path)
    calls = []
    callbacks = [Mock(), Mock()]

    class Engine:
        async def synthesize_async(self, text, path, *, chunk_callback=None, progress_callback=None):
            calls.append((self, text, path, progress_callback))
            await asyncio.sleep(0)
            path.write_bytes(text.encode())
            chunk_callback(0, path, text)
            return path

    engines = [Engine(), Engine()]
    session.engine_obj = Engine()
    session.output_path = tmp_path / "unrelated.mp3"
    session.allowed = {}
    progress = [Mock(), Mock()]
    paths = [tmp_path / "first.mp3", tmp_path / "second.mp3"]
    results = await asyncio.gather(*(
        session._synthesize_safe(engine, text, path, chunk_callback=callback,
            progress_callback=on_progress, unsupported_keyword="must be filtered")
        for engine, text, path, callback, on_progress in zip(
            engines, ("first", "second"), paths, callbacks, progress
        )
    ))
    assert results == paths
    assert len(calls) == 2
    for index, expected in enumerate(engines):
        _, text, path, on_progress = next(entry for entry in calls if entry[0] is expected)
        assert text == ("first", "second")[index]
        assert path == paths[index]
        assert on_progress is progress[index]
        assert path.read_bytes() == text.encode()
        assert callbacks[index].call_args.args[:3] == (0, path, text)
        assert callbacks[index].call_args.kwargs["observation"] is not None
    assert not session.output_path.exists()


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", [RuntimeError("provider failed"), asyncio.CancelledError()])
async def test_nested_invocation_preserves_failure_identity_and_retires_late_callback(tmp_path, failure):
    session = await prepare_synthesizer(tmp_path)
    callback = Mock()
    captured = []

    class Engine:
        async def synthesize_async(self, text, path, *, chunk_callback=None):
            captured.append(chunk_callback)
            raise failure

    with pytest.raises(type(failure)) as raised:
        await session._synthesize_safe(Engine(), "text", tmp_path / "failed.mp3", chunk_callback=callback)
    assert raised.value is failure
    assert len(captured) == 1
    captured[0](0, tmp_path / "late.mp3", "late")
    callback.assert_not_called()
