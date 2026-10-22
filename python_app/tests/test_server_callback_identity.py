"""Chapter callbacks retain their invocation when sibling work changes job state."""

from __future__ import annotations

import asyncio
import contextlib
import copy
import threading
import time
import uuid
from contextlib import asynccontextmanager
from types import SimpleNamespace
from unittest.mock import Mock, call

import pytest

from python_app.src import server_chapter_execution as execution
from python_app.src.conversion_control import ConversionControl
from python_app.src.server_chapter_preparation import _server_chapter_preparation
from python_app.src.server_chapter_state import ServerChapterState
from python_app.src.server_chapter_synthesis import _server_chapter_synthesis
from python_app.src.server_conversion_state import ServerConversionState
from python_app.src.server_metadata_preparation import _server_metadata_preparation
from python_app.src.server_stream_index import _retired_stream_chunks
from python_app.src.stream_attempt_observation import StreamAttempt


def make_chapter(index: int, text: str) -> ServerChapterState:
    chapter = ServerChapterState(
        idx=index, chapter_obj=SimpleNamespace(name=f"Chapter {index}", text=text), preferred_engine=None
    )
    chapter.attempt = 1
    chapter.chapter_name = chapter.chapter_obj.name
    return chapter


def preparation_session(tmp_path):
    configuration = SimpleNamespace(engine="piper")
    return SimpleNamespace(
        job={}, job_id="shared-job", chapters=[object(), object()], job_output_dir=tmp_path,
        max_chapter_attempts=1, max_chapter_attempts_label="1", active_config=configuration,
        config=configuration, auto_mode=False,
        _advance_chapter_progress=Mock(),
        # These intentionally disagree with every live chapter. The scheduler
        # updates job-level loop variables while older callbacks are pending.
        idx=77, chapter_name="Unrelated sibling", clean_text="Unrelated text",
    )


def preparation_runtime(tmp_path):
    manifest = {}
    stream_dir = tmp_path / "streams"
    stream_dir.mkdir()
    runtime = SimpleNamespace(
        _append_event=Mock(), _set_chapter_status=Mock(), MAX_CHAPTER_CHARS=0,
        FileManager=SimpleNamespace(sanitize_filename=lambda name: name),
        TextFormattingProcessor=SimpleNamespace(strip_inline_markdown=lambda text: text),
        TextValidator=SimpleNamespace(estimate_duration=lambda text: float(len(text))),
        _build_text_preview=lambda text: "", _job_stream_dir=lambda *_args, **_kwargs: stream_dir,
        _stream_manifest_lock=threading.RLock(),
        _load_stream_index=lambda _job_id: copy.deepcopy(manifest),
        _resolve_relative_path_within_root=lambda root, name, **_kwargs: root / name,
        uuid=uuid, time=time, contextlib=contextlib, logger=Mock(),
    )

    def save(_job_id, payload):
        manifest.clear()
        manifest.update(copy.deepcopy(payload))

    runtime._save_stream_index = save
    runtime._retired_stream_chunks = lambda *args: _retired_stream_chunks(runtime, *args)
    return runtime, manifest, stream_dir


@pytest.mark.asyncio
async def test_progress_and_stream_publications_keep_chapter_identity_when_interleaved(tmp_path):
    session = preparation_session(tmp_path)
    runtime, manifest, stream_dir = preparation_runtime(tmp_path)
    first, second = make_chapter(1, "First body"), make_chapter(2, "Second body")
    for chapter in (first, second):
        assert await _server_chapter_preparation(runtime, session, chapter) is None
    first._progress_callback("first segment", 100)
    session.idx = 2
    second._progress_callback("second segment", 200)
    session.idx = 99
    first._progress_callback("first again", 100)
    assert session._advance_chapter_progress.call_args_list == [
        call(1, "first segment", 100), call(2, "second segment", 200), call(1, "first again", 100)
    ]
    assert first._segment_progress_state == {"hits": 2}
    assert second._segment_progress_state == {"hits": 1}

    source = tmp_path / "segment.mp3"
    first_attempt, second_attempt = StreamAttempt(), StreamAttempt()
    first_callback = first_attempt.wrap(first._chunk_callback)
    second_callback = second_attempt.wrap(second._chunk_callback)
    source.write_bytes(b"first original")
    first_callback(0, source, "first segment")
    original = copy.deepcopy(manifest["chapters"]["1"]["chunks"][0])
    source.write_bytes(b"second")
    second_callback(0, source, "second segment")
    source.write_bytes(b"first replacement")
    first_callback(0, source, "first replacement")
    for index, expected in ((1, b"first replacement"), (2, b"second")):
        chapter_manifest = manifest["chapters"][str(index)]
        assert chapter_manifest["chapterIndex"] == index
        assert chapter_manifest["baseUrl"] == f"/api/streams/shared-job/chapters/{index}"
        chunk = chapter_manifest["chunks"][0]
        assert chunk["url"] == f"/api/streams/shared-job/chapters/{index}/chunks/{chunk['id']}"
        assert (stream_dir / chunk["file"]).read_bytes() == expected
    replacement = manifest["chapters"]["1"]["chunks"][0]
    assert original["id"] != replacement["id"]
    assert (stream_dir / original["file"]).read_bytes() == b"first original"
    assert manifest["chapters"]["1"]["retiredChunks"] == [
        {"id": original["id"], "file": original["file"]}
    ]
    first_attempt.close()
    second_attempt.close()
    completed = copy.deepcopy(manifest)
    source.write_bytes(b"late cancelled callback")
    first_callback(1, source, "late")
    assert manifest == completed


@pytest.mark.asyncio
async def test_interleaved_heartbeats_use_their_live_chapter_not_scheduler_loop_variables(tmp_path, monkeypatch):
    session = preparation_session(tmp_path)
    chapters = [make_chapter(1, "First"), make_chapter(2, "Second")]
    observed = []
    runtimes = []
    for chapter in chapters:
        chapter.start_time = 0.0
        chapter.estimated_seconds = 30.0
        chapter.local_active_config = SimpleNamespace(engine="piper")
        chapter.heartbeat_stop = asyncio.Event()
        recorded = asyncio.Event()
        timed_out = [False]

        async def wait_for(awaitable, timeout, timed_out=timed_out):
            if not timed_out[0]:
                timed_out[0] = True
                awaitable.close()
                raise asyncio.TimeoutError()
            return await awaitable

        def append(job, message, recorded=recorded):
            observed.append((job["statusHint"], message))
            recorded.set()

        runtimes.append(SimpleNamespace(
            asyncio=SimpleNamespace(create_task=asyncio.create_task, wait_for=wait_for, TimeoutError=asyncio.TimeoutError),
            time=SimpleNamespace(time=lambda: 10.0), _CHAPTER_HEARTBEAT_SECONDS=0,
            TimeFormatter=SimpleNamespace(format_time=lambda value: f"{value:.1f}s"),
            _update_job_activity=Mock(), _persist_job=Mock(), _append_event=append,
            heartbeat_recorded=recorded,
        ))

    async def stop_after_heartbeat(runtime, _session, chapter):
        await runtime.heartbeat_recorded.wait()
        return ConversionControl("return", chapter)

    monkeypatch.setattr(execution, "_server_chapter_preflight", stop_after_heartbeat)
    try:
        results = await asyncio.gather(*(
            execution._server_chapter_execution(runtime, session, chapter)
            for runtime, chapter in zip(runtimes, chapters)
        ))
        assert [result.value for result in results] == chapters
        assert len(observed) == 2
        for index in (1, 2):
            hint, message = next(
                entry for entry in observed if f"⏳ Chapter {index}:" in entry[1]
            )
            assert f"Chapter {index}/2: Chapter {index}" in hint
            assert "Unrelated sibling" not in hint + message
    finally:
        for chapter in chapters:
            chapter.heartbeat_stop.set()
        await asyncio.gather(*(chapter.heartbeat_task for chapter in chapters))
    assert "statusHint" not in session.job


@pytest.mark.asyncio
@pytest.mark.parametrize("accepts_callbacks", [True, False])
async def test_synthesis_invocation_uses_each_leased_engine_and_text(tmp_path, accepts_callbacks):
    calls = []

    class CallbackEngine:
        async def synthesize_async(self, text, path, **kwargs):
            calls.append((self, text, path, kwargs))
            await asyncio.sleep(0)
            return path

    class LegacyEngine:
        async def synthesize_async(self, text, path):
            calls.append((self, text, path, {}))
            await asyncio.sleep(0)
            return path

    engine_type = CallbackEngine if accepts_callbacks else LegacyEngine
    engines = {name: engine_type() for name in ("first", "second")}
    poison = engine_type()
    released = []

    @asynccontextmanager
    async def lease(name):
        try:
            yield SimpleNamespace(engine=name), engines[name]
        finally:
            released.append(name)

    session = preparation_session(tmp_path)
    session.engine_pool = SimpleNamespace(use=lease)
    session.engine_obj = poison
    session.auto_mode = False
    session.edge_slow_mode = False
    session._resolve_tts_output = lambda output, engine: (output, False)
    chapters = [make_chapter(index, name) for index, name in enumerate(engines, 1)]
    for chapter, name in zip(chapters, engines):
        chapter.engine_name = name
        chapter.output_file = tmp_path / f"{name}.mp3"
        chapter.clean_text = f"Owned {name} text"
        chapter.chapter_timeout = 10
        chapter._progress_callback = Mock()
        chapter._chunk_callback = Mock()
        chapter._segment_progress_state = {"hits": 0}

    async def deadline(task, **_kwargs):
        await task
        # Stop at the exercised synthesis seam, before audio validation.
        raise asyncio.CancelledError()

    async def safe_cancel(task, **_kwargs):
        if task is not None:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

    runtime = SimpleNamespace(
        asyncio=asyncio, contextlib=contextlib, time=time,
        os=SimpleNamespace(getenv=lambda *_args: "0"),
        observe_synthesis=lambda invoke, callback: invoke(callback),
        _await_task_with_deadline=deadline, _safe_cancel_task=safe_cancel,
    )
    results = await asyncio.gather(*(
        _server_chapter_synthesis(runtime, session, chapter) for chapter in chapters
    ), return_exceptions=True)
    assert all(isinstance(result, asyncio.CancelledError) for result in results)
    assert len(calls) == 2
    for name, expected in engines.items():
        _, text, path, kwargs = next(entry for entry in calls if entry[0] is expected)
        assert text == f"Owned {name} text"
        assert path == tmp_path / f"{name}.mp3"
        assert bool(kwargs) is accepts_callbacks
    assert sorted(released) == ["first", "second"]


@pytest.mark.asyncio
async def test_tts_log_callback_uses_its_message_in_generator_scope():
    class StopAfterBinding(Exception):
        pass

    session = ServerConversionState(job_id="log-job")
    session.job = {}
    session.message = "ordinary job-level message"
    runtime = SimpleNamespace(
        _append_event=Mock(), _book_slug=Mock(side_effect=StopAfterBinding)
    )
    with pytest.raises(StopAfterBinding):
        await _server_metadata_preparation(runtime, session)
    session.tts_log_callback("model loading for this callback")
    assert session.job["statusHint"] == "model loading for this callback"
    assert runtime._append_event.call_count == 1
    session.message = "model loading in an unrelated job-level value"
    session.tts_log_callback("ordinary callback output")
    assert session.job["statusHint"] == "model loading for this callback"
    assert session.job["_raw_log"] == ["model loading for this callback", "ordinary callback output"]
    assert runtime._append_event.call_count == 1
