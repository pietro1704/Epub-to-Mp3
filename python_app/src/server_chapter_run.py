# -*- coding: utf-8 -*-
"""Coordinate server chapter phases and original control flow."""

from __future__ import annotations

from typing import Optional

from .conversion_control import ConversionControl as _ConversionControl
from .ebook_reader import Chapter as Chapter
from .server_chapter_execution import _server_chapter_execution
from .server_chapter_preparation import _server_chapter_preparation


async def _server_chapter_run(_runtime, _state, _chapter):
    if _state.job_failed["value"] or _state._should_abort_current_run():
        return _ConversionControl("return", None)

    _chapter.attempt = _state._note_chapter_attempt(_chapter.idx)

    _chapter.chapter_name = getattr(_chapter.chapter_obj, "name", f"Chapter {_chapter.idx}")
    _state.job["_currentChapterIndex"] = _chapter.idx
    _state.job["currentChapter"] = _chapter.chapter_name
    _state.job["parallelActive"] = _state.job.get("parallelActive", 0) + 1
    _state.job["statusHint"] = f"Chapter {_chapter.idx}/{len(_state.chapters)}: {_chapter.chapter_name}"
    _chapter.start_time = _runtime.time.time()
    _chapter.heartbeat_stop = _runtime.asyncio.Event()
    _chapter.heartbeat_task: Optional[_runtime.asyncio.Task] = None
    _runtime._update_job_activity(_state.job, stage=f"chapter_{_chapter.idx}_start")

    try:
        _phase_flow = await _server_chapter_preparation(_runtime, _state, _chapter)
        if _phase_flow is not None:
            return _phase_flow
        _phase_flow = await _server_chapter_execution(_runtime, _state, _chapter)
        if _phase_flow is not None:
            return _phase_flow
    finally:
        _chapter.heartbeat_stop.set()
        if _chapter.heartbeat_task:
            with _runtime.contextlib.suppress(_runtime.asyncio.CancelledError):
                await _chapter.heartbeat_task
        _state.job.pop("statusHint", None)
        _state.job["parallelActive"] = max(_state.job.get("parallelActive", 1) - 1, 0)
