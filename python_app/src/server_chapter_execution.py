# -*- coding: utf-8 -*-
"""Server chapter execution."""

from __future__ import annotations

from .ebook_reader import Chapter as Chapter
from .server_chapter_audio_acceptance import _server_chapter_audio_acceptance
from .server_chapter_preflight import _server_chapter_preflight
from .server_chapter_synthesis import _server_chapter_synthesis


async def _server_chapter_execution(_runtime, _state, _chapter):
    async def _chapter_heartbeat_loop() -> None:
        progress_tick = 5.0
        last_log_ts = _chapter.start_time
        last_disk_persist_ts = _chapter.start_time
        _DISK_PERSIST_INTERVAL = 60.0  # Write _lastActivityTs to disk every 60s
        try:
            while True:
                try:
                    await _runtime.asyncio.wait_for(
                        _chapter.heartbeat_stop.wait(),
                        timeout=progress_tick,
                    )
                    break
                except _runtime.asyncio.TimeoutError:
                    now = _runtime.time.time()
                    elapsed = now - _chapter.start_time
                    # Keep _lastActivityTs fresh in memory so the stall watchdog
                    # doesn't trigger false positives during active synthesis.
                    _runtime._update_job_activity(_state.job)
                    # Flush _lastActivityTs to disk periodically so a crash
                    # during a long chapter doesn't leave a stale timestamp
                    # that triggers the stall watchdog on the next restart.
                    if now - last_disk_persist_ts >= _DISK_PERSIST_INTERVAL:
                        _runtime._persist_job(_state.job_id, force=True)
                        last_disk_persist_ts = now
                    if (now - last_log_ts) < _runtime._CHAPTER_HEARTBEAT_SECONDS:
                        continue
                    last_log_ts = now
                    engine_label = (
                        _chapter.local_active_config.engine
                        if _chapter.local_active_config
                        else _state.config.engine
                    ) or "auto"
                    in_progress = _runtime.TimeFormatter.format_time(elapsed)
                    remaining = max(0.0, _chapter.estimated_seconds - elapsed)
                    hint = f"Chapter {_chapter.idx}/{len(_state.chapters)}: {_chapter.chapter_name} for {_runtime.TimeFormatter.format_time(elapsed)}"
                    if remaining > 0:
                        hint += f" • estimated remaining {_runtime.TimeFormatter.format_time(remaining)}"
                    _state.job["statusHint"] = hint
                    _runtime._append_event(
                        _state.job,
                        f"⏳ {_chapter.chapter_name}: {in_progress} using {engine_label.upper()}",
                    )
                    _runtime._persist_job(_state.job_id, force=False)
        finally:
            _state.job.pop("statusHint", None)
    _chapter._chapter_heartbeat_loop = _chapter_heartbeat_loop

    _chapter.heartbeat_task = _runtime.asyncio.create_task(_chapter._chapter_heartbeat_loop())

    while True:
        _phase_flow = await _server_chapter_preflight(_runtime, _state, _chapter)
        if _phase_flow is not None:
            if _phase_flow.kind == "break":
                break
            if _phase_flow.kind == "continue":
                continue
            return _phase_flow
        _phase_flow = await _server_chapter_synthesis(_runtime, _state, _chapter)
        if _phase_flow is not None:
            if _phase_flow.kind == "break":
                break
            if _phase_flow.kind == "continue":
                continue
            return _phase_flow
        _phase_flow = await _server_chapter_audio_acceptance(_runtime, _state, _chapter)
        if _phase_flow is not None:
            if _phase_flow.kind == "break":
                break
            if _phase_flow.kind == "continue":
                continue
            return _phase_flow

    await _runtime._apply_server_silence_padding(_state.job, _chapter.output_file, _state.config)

    _chapter.engine_runtime = max((_chapter.last_stage_timestamp - _chapter.synth_started), 0.001)

    _runtime._append_event(
        _state.job,
        f"✅ Completed: {_chapter.output_file.name} ({_runtime.TimeFormatter.format_time(_chapter.chapter_elapsed)})",
    )
    # Successful Edge chapter resets the consecutive timeout counter.
    if (_chapter.local_active_config and _chapter.local_active_config.engine or "").lower() == "edge":
        _state.edge_chapter_timeouts[0] = 0

    # Add download URL to chapter progress
    _chapter.chapter_output = {
        "name": _chapter.output_file.name,
        "url": f"/api/outputs/{_state.job_id}/{_chapter.output_file.name}",
        "durationSeconds": round(_chapter.duration_seconds, 2),
        "sizeBytes": _chapter.output_file.stat().st_size,
    }
    # SHA-256 lets the iOS client verify the downloaded chapter
    # against the manifest.  Failures are non-fatal.
    with _runtime.contextlib.suppress(Exception):
        from src._server_audio_helpers import compute_mp3_sha256
        _chapter.compute_mp3_sha256 = compute_mp3_sha256

        _chapter.chapter_output["sha256"] = _chapter.compute_mp3_sha256(_chapter.output_file)
    # Include retry count if chapter required retries
    _chapter.retry_count = _chapter.attempt - 1 if _chapter.attempt > 1 else None
    _runtime._set_chapter_status(
        _state.job,
        _chapter.idx,
        "completed",
        download_url=_chapter.chapter_output["url"],
        engine_label=(
            _chapter.local_active_config.engine
            if _chapter.local_active_config
            else _chapter.local_engine_name or _state.config.engine
        ),
        retry_count=_chapter.retry_count,
    )
    _state._refresh_chapter_completion()
    _state._complete_chapter_progress(_chapter.idx, output_path=_chapter.output_file)
    _runtime._update_job_activity(_state.job, stage=f"chapter_{_chapter.idx}_completed")

    # **OPTIMIZATION #2**: Batch persist - only persist every 5 chapters or on critical milestones
    _chapter.chapters_completed = _state.job.get("chaptersCompleted", 0)
    _chapter.should_persist = (
        _chapter.chapters_completed % 5 == 0  # Every 5 chapters
        or _chapter.chapters_completed == len(_state.chapters)  # Last chapter
        or _chapter.chapters_completed == 1  # First chapter
    )
    _runtime._persist_job(_state.job_id, force=_chapter.should_persist)

    # Write a lightweight progress checkpoint every 5 chapters so
    # _preload_existing_outputs can recover quickly without scanning all MP3s.
    if _chapter.should_persist:
        _runtime._write_progress_checkpoint(_state.job_id, _state.job, _state.job_output_dir)

    _state.outputs.append(_chapter.chapter_output)
    if _state.zip_open and _chapter.output_file.exists():
        async with _state.zip_lock:
            try:
                _state.zip_archive.write(_chapter.output_file, arcname=_chapter.output_file.name)
            except Exception:
                pass

    _runtime.telemetry.record_sample(
        engine=(_chapter.local_active_config.engine if _chapter.local_active_config else _state.config.engine),
        voice=(_chapter.local_active_config.voice if _chapter.local_active_config else None),
        chars=len(_chapter.clean_text),
        synth_seconds=_chapter.engine_runtime or _chapter.chapter_elapsed,
        total_seconds=_chapter.chapter_elapsed,
        audio_seconds=_chapter.duration_seconds,
        job_id=_state.job_id,
        chapter=_chapter.chapter_name,
        language=getattr(_chapter.local_active_config or _state.config, "primary_language", None),
    )
    if _chapter.engine_runtime and _chapter.local_active_config:
        _chapter.chars_per_second = len(_chapter.clean_text) / max(_chapter.engine_runtime, 0.001)
        _runtime._append_event(
            _state.job,
            f"⏱️ {_chapter.local_active_config.engine.upper()} ≈ {_chapter.chars_per_second:.1f} chars/s",
        )
        _chapter.entry = _state.job["chapterProgress"][_chapter.idx - 1]
        if isinstance(_chapter.entry, dict):
            _chapter.entry["elapsedSeconds"] = round(_chapter.chapter_elapsed, 2)
            _chapter.entry["charsPerSecond"] = round(_chapter.chars_per_second, 1)
        if (
            _state.edge_auto_tune
            and (_chapter.local_active_config.engine or "").lower() == "edge"
            # Skip speed judgement for tiny chapters (< 500 chars) — overhead
            # dominates and produces artificially low chars/s readings
            # (e.g. a "Cover" chapter with 5 chars reads as 3 chars/s).
            and len(_chapter.clean_text) >= 500
            and (
                _chapter.chars_per_second < _runtime.EDGE_MIN_CHARS_PER_SECOND
                or (
                    _chapter.estimated_seconds > 0
                    and _chapter.chapter_elapsed
                    > (_chapter.estimated_seconds * _runtime.EDGE_SLOW_RATIO_THRESHOLD)
                )
            )
        ):
            _state._apply_edge_slow_mode(f"low speed ({_chapter.chars_per_second:.1f} chars/s)")
