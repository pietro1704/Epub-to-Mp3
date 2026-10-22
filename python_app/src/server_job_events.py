# -*- coding: utf-8 -*-
"""Job activity, SSE broadcast and chapter event delivery."""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Optional

from .config import ConversionConfig


def _sanitize_event_message(_runtime, message: str) -> str:
    for prefix in _runtime._EVENT_PREFIXES:
        if message.startswith(prefix):
            return message[len(prefix) :].strip()
    return message


async def _segment_idle_watchdog(_runtime,
    task: asyncio.Task,
    progress_state: dict,
    idle_seconds: float,
    chapter_index: int,
    *,
    check_interval: float = 10.0,
) -> None:
    """Cancel ``task`` if ``progress_state['hits']`` stops advancing.

    Per-chapter heartbeat monitor used by the web conversion path; mirrors
    ``_HealthWatchdogMixin._watch_segment_idle`` on the CLI side.  Runs
    independent of any shared activity clock so parallel chapters cannot
    keep a silently-stalled engine alive.
    """
    if task is None or task.done() or idle_seconds <= 0:
        return
    try:
        last_hits = int(progress_state.get("hits", 0))
    except Exception:
        last_hits = 0
    last_advance = _runtime.time.time()
    interval = max(2.0, float(check_interval))
    while not task.done():
        await _runtime.asyncio.sleep(interval)
        if task.done():
            return
        try:
            current = int(progress_state.get("hits", 0))
        except Exception:
            current = last_hits
        if current != last_hits:
            last_hits = current
            last_advance = _runtime.time.time()
            continue
        if (_runtime.time.time() - last_advance) >= idle_seconds:
            print(
                f"🛟 Idle watchdog: chapter {chapter_index} emitted no "
                f"segment for {int(idle_seconds)}s — aborting engine"
            )
            await _runtime._safe_cancel_task(task, grace=10.0)
            return


def _update_job_activity(_runtime, job: Optional[dict], stage: Optional[str] = None) -> None:
    if not job:
        return
    now = _runtime.time.time()
    job["_lastActivityTs"] = now
    if stage:
        job["_lastStage"] = stage


def _append_event(_runtime, job: dict, message: str, *, raw: Optional[str] = None) -> None:
    events = job.setdefault("events", [])
    events.append(message)
    raw_log = job.setdefault("_raw_log", [])
    plain = raw if raw is not None else _runtime._sanitize_event_message(message)
    timestamp = _runtime.datetime.now(_runtime.timezone.utc).strftime("%H:%M:%S")
    raw_log.append(f"{timestamp} {plain}")

    # **OPTIMIZATION #3**: Broadcast event to SSE clients
    _runtime._schedule_job_broadcast(job.get("jobId"), job)
    _runtime._update_job_activity(job)


async def _apply_server_silence_padding(_runtime,
    job: dict, output_file: Path, config: ConversionConfig
) -> None:
    """Pad a finalised chapter MP3 with configured intro/outro silence.

    Mirrors the CLI path (`converter._apply_silence_padding`).  Errors are
    logged into the job event stream but do not fail the chapter.
    """
    intro = max(int(getattr(config, "chapter_intro_silence_ms", 0) or 0), 0)
    outro = max(int(getattr(config, "chapter_outro_silence_ms", 0) or 0), 0)
    if intro == 0 and outro == 0:
        return
    ok, error = await _runtime.add_silence_padding(
        output_file,
        intro_ms=intro,
        outro_ms=outro,
        bitrate=getattr(config, "bitrate", "8k") or "8k",
        sample_rate=int(getattr(config, "sample_rate", 16_000) or 16_000),
        channels=int(getattr(config, "channels", 1) or 1),
    )
    if not ok:
        _runtime._append_event(job, f"⚠️ silence padding failed for {output_file.name}: {error}")


async def _broadcast_sse_event(_runtime, job_id: str, job_data: dict) -> None:
    """**OPTIMIZATION #3**: Broadcast job update to all SSE clients."""
    if job_id not in _runtime._sse_clients:
        return

    payload = _runtime._job_status_payload(job_data)
    raw_log = payload.get("rawLog")
    if isinstance(raw_log, list) and len(raw_log) > _runtime._SSE_RAW_LOG_CAP:
        payload["rawLog"] = raw_log[-_runtime._SSE_RAW_LOG_CAP:]
    dead_queues = set()

    for queue in _runtime._sse_clients[job_id]:
        try:
            queue.put_nowait(payload)
        except _runtime.asyncio.QueueFull:
            # Client is slow, disconnect them
            dead_queues.add(queue)
        except Exception:
            dead_queues.add(queue)

    # Clean up disconnected clients
    if dead_queues:
        _runtime._sse_clients[job_id] -= dead_queues
        if not _runtime._sse_clients[job_id]:
            del _runtime._sse_clients[job_id]


def _schedule_job_broadcast(_runtime, job_id: Optional[str], job_data: Optional[dict]) -> None:
    """Dispatch job updates to SSE listeners even from worker threads."""
    if not job_id or not job_data:
        return
    if job_id not in _runtime._sse_clients:
        return
    try:
        loop = _runtime.asyncio.get_running_loop()
        loop.create_task(_runtime._broadcast_sse_event(job_id, job_data))
        return
    except RuntimeError:
        pass

    if _runtime._app_loop is None or _runtime._app_loop.is_closed():
        return

    def _dispatch() -> None:
        _runtime._app_loop.create_task(_runtime._broadcast_sse_event(job_id, job_data))

    _runtime._app_loop.call_soon_threadsafe(_dispatch)


async def _broadcast_chapter_event(_runtime, job_id: str, chapter_data: dict) -> None:
    """Emit a typed 'chapter_update' SSE event to all SSE clients of job_id."""
    if job_id not in _runtime._sse_clients:
        return
    payload = {"_sse_event": "chapter_update", **chapter_data}
    dead_queues = set()
    for queue in _runtime._sse_clients[job_id]:
        try:
            queue.put_nowait(payload)
        except (_runtime.asyncio.QueueFull, Exception):
            dead_queues.add(queue)
    if dead_queues:
        _runtime._sse_clients[job_id] -= dead_queues
        if not _runtime._sse_clients[job_id]:
            del _runtime._sse_clients[job_id]


def _schedule_chapter_broadcast(_runtime, job_id: Optional[str], chapter_data: Optional[dict]) -> None:
    """Dispatch a per-chapter SSE event from any thread."""
    if not job_id or not chapter_data:
        return
    if job_id not in _runtime._sse_clients:
        return
    try:
        loop = _runtime.asyncio.get_running_loop()
        loop.create_task(_runtime._broadcast_chapter_event(job_id, chapter_data))
        return
    except RuntimeError:
        pass
    if _runtime._app_loop is None or _runtime._app_loop.is_closed():
        return
    _runtime._app_loop.call_soon_threadsafe(
        lambda: _runtime._app_loop.create_task(_runtime._broadcast_chapter_event(job_id, chapter_data))
    )


def _job_status_payload(_runtime, job_data: dict) -> dict:
    payload = dict(job_data)
    payload["rawLog"] = job_data.get("_raw_log", [])
    payload.pop("_raw_log", None)
    payload["lastActivityAt"] = job_data.get("_lastActivityTs")
    return payload
