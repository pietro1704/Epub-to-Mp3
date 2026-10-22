# -*- coding: utf-8 -*-
"""Server retry scheduler."""

from __future__ import annotations

from typing import Optional

from .conversion_control import ConversionControl as _ConversionControl
from .ebook_reader import Chapter as Chapter


async def _server_retry_scheduler(_runtime, _state):
    while _state.pending_chapters:
        if _state.retry_round > 0:
            _state._mark_retry_round(_state.retry_round, len(_state.pending_chapters))
        else:
            _state.retrying_failed_chapters = False
        _runtime._update_job_activity(_state.job, stage="conversion_loop")
        _state.running_tasks: set[_runtime.asyncio.Task] = set()
        _state.cursor = 0
        _state.slot_task_engine: dict[_runtime.asyncio.Task, str] = {}  # task → engine it was assigned
        _state._maybe_adjust_parallel_slots(force=True)

        def _next_slot_engine() -> Optional[str]:
            """Return the engine name for the next slot to be filled."""
            if not _state.slot_affinity:
                return None
            slot_idx = len(_state.running_tasks)
            return _state.slot_affinity[slot_idx] if slot_idx < len(_state.slot_affinity) else None
        _state._next_slot_engine = _next_slot_engine

        while _state.cursor < len(_state.pending_chapters) or _state.running_tasks:
            _state.abort_requested = _state.job.get("cancelRequested") or _state.job.get("_run_token") != _state.run_token
            if not _state.job_failed["value"] and not _state.abort_requested:
                _state._maybe_adjust_parallel_slots()
                while len(_state.running_tasks) < _state.parallel_slots and _state.cursor < len(_state.pending_chapters):
                    _state.idx, _state.chapter = _state.pending_chapters[_state.cursor]
                    _state.cursor += 1
                    _state.pref = _state._next_slot_engine()
                    _state.task = _runtime.asyncio.create_task(
                        _state.convert_chapter(_state.idx, _state.chapter, preferred_engine=_state.pref)
                    )
                    _state.slot_task_engine[_state.task] = _state.pref or ""
                    _state.running_tasks.add(_state.task)
            if _state.abort_requested:
                for _state.task in _state.running_tasks:
                    _state.task.cancel()
                if _state.running_tasks:
                    await _runtime.asyncio.gather(*_state.running_tasks, return_exceptions=True)
                break
            if not _state.running_tasks:
                break
            _state.done, _state.running_tasks = await _runtime.asyncio.wait(
                _state.running_tasks,
                timeout=1.0,
                return_when=_runtime.asyncio.FIRST_COMPLETED,
            )
            _state._maybe_health_check()
            if not _state.done:
                continue
            _state.freed_engines: list[str] = []
            for _state.task in _state.done:
                _state.freed_engines.append(_state.slot_task_engine.pop(_state.task, ""))
                try:
                    _state.task.result()
                except _runtime.asyncio.CancelledError:
                    pass
                except Exception as exc:
                    _state.exc = exc
                    _state.job_failed["value"] = True
                    _runtime._append_event(_state.job, f"❌ Unexpected error while converting chapter: {_state.exc}")
                    _runtime._persist_job(_state.job_id, force=True)
            _state._maybe_adjust_parallel_slots()
            # Refill slots with the same engine affinity the freed slot had.
            for _state.freed_engine in _state.freed_engines:
                if len(_state.running_tasks) >= _state.parallel_slots or _state.cursor >= len(_state.pending_chapters):
                    break
                _state.idx, _state.chapter = _state.pending_chapters[_state.cursor]
                _state.cursor += 1
                _state.pref = _state.freed_engine if (_state.freed_engine and _state.slot_affinity) else None
                _state.task = _runtime.asyncio.create_task(_state.convert_chapter(_state.idx, _state.chapter, preferred_engine=_state.pref))
                _state.slot_task_engine[_state.task] = _state.pref or ""
                _state.running_tasks.add(_state.task)

        if _state.job.get("cancelRequested") or _state.job.get("_run_token") != _state.run_token:
            break
        if _state.job_failed["value"]:
            break

        _state.failed_chapters = _state._collect_failed_chapters()
        _state.missing_chapters = _state._collect_missing_chapters()
        if _state.missing_chapters:
            _state.expected_count = sum(1 for chapter in _state.chapters if _state._chapter_requires_audio(chapter))
            _state.actual_count = len(
                [
                    path
                    for path in _state.job_output_dir.glob("*.mp3")
                    if not path.name.lower().startswith("tmp")
                ]
            )
            _runtime._append_event(
                _state.job,
                f"🔍 Verifying final files: {_state.actual_count}/{_state.expected_count} found; reprocessing pending chapters",
            )
            _state.failed_index_set = {idx for idx, _ in _state.failed_chapters}
            for _state.idx, _state.chapter in _state.missing_chapters:
                if _state.idx in _state.failed_index_set:
                    continue
                _runtime._set_chapter_status(_state.job, _state.idx, "failed")
                _state.failed_chapters.append((_state.idx, _state.chapter))
        _state.failed_indices = {idx for idx, _ in _state.failed_chapters}
        _state._sync_soft_failures(_state.failed_indices)
        if not _state.failed_chapters:
            break

        _state.retryable = [
            (idx, chapter) for idx, chapter in _state.failed_chapters if _state._chapter_can_retry(idx)
        ]
        if _state.retryable and (_state.retry_forever or _state.retry_round < _state.max_retry_rounds):
            _state.retry_round += 1
            for _state.idx, _state._ in _state.retryable:
                _runtime._set_chapter_status(_state.job, _state.idx, "pending")
                _state._reset_chapter_progress_tracking(_state.idx)
            if _state.retry_forever and _runtime._CHAPTER_RETRY_BACKOFF_SECONDS > 0:
                await _runtime.asyncio.sleep(_runtime._CHAPTER_RETRY_BACKOFF_SECONDS)
            _state.pending_chapters = _state.retryable
            continue

        _state.preview = ", ".join(
            f"#{idx} {getattr(chapter, 'name', f'Chapter {idx}')}"
            for idx, chapter in _state.failed_chapters[:3]
        )
        if len(_state.failed_chapters) > 3:
            _state.preview += f" … (+{len(_state.failed_chapters) - 3})"
        _state.failure_message = f"{len(_state.failed_chapters)} chapter(s) failed after {_state.max_chapter_attempts_label} attempt(s)."
        _runtime._append_event(_state.job, f"❌ {_state.failure_message}")
        if _state.preview:
            _runtime._append_event(_state.job, f"   ↳ Chapters: {_state.preview}")
        _state.job["state"] = "failed"
        _runtime._set_job_error(_state.job, _state.failure_message)
        _state.job["completedAt"] = _runtime.time.time()
        _state.job["completedAtIso"] = _runtime._utcnow_iso()
        _state.job["parallelActive"] = 0
        _runtime._persist_job(_state.job_id, force=True)
        _runtime._persist_job_log(_state.job_id, _state.job)
        return _ConversionControl("return", None)

    _state.retrying_failed_chapters = False

    # Auto-dedup + validate (mirror of CLI's _auto_validate_and_retry_async).
    # Web jobs previously skipped the post-conversion sanity check, so a
    # Carl-style situation where two MP3s end up under different
    # filenames for the same chapter went undetected. This block:
    #   1. Collapses duplicate MP3s in the output dir, keeping the
    #      longest-duration file per chapter index.
    #   2. Runs validate_book and surfaces any remaining issues
    #      through the job event log so the UI can display them.
    # Chapter re-synthesis is *not* retried here — the inline retry
    # loop above already handled deterministic failures, and the
    # server's `convert_chapter` closure is not callable from this
    # scope. Operators can re-trigger conversion from the UI when
    # the issue list is non-trivial.
    try:
        _state.removed_dups = _runtime._server_dedup_chapter_outputs(_state.job_output_dir)
        if _state.removed_dups:
            _runtime._append_event(_state.job, f"🧹 Auto-dedup: removed {_state.removed_dups} duplicate MP3(s)")
        _runtime._update_job_activity(_state.job, stage="auto_dedup_done")

        _state.source_path = _runtime._resolve_job_source_path(_state.job.get("file_path") or "", must_exist=False)
        if _state.source_path and _state.source_path.exists():
            from validate_conversion import validate_book as _validate_book
            _state._validate_book = _validate_book

            # `validate_book` may return `None` when it fails early
            # (e.g. cache directory unresolved for a fresh job that
            # never wrote one). That's not an error condition — just
            # nothing to report — so we skip the event log instead
            # of letting the unpack raise.
            _state.result = _state._validate_book(_state.source_path, output_dir=_state.job_output_dir)
            if _state.result is not None:
                _state.stats, _state.issues = _state.result
                _state.real_issues = [i for i in _state.issues if "Missing cache" not in i]
                _state.job["validationStats"] = _state.stats
                _state.job["validationIssues"] = _state.real_issues
                if _state.real_issues:
                    _runtime._append_event(
                        _state.job,
                        f"⚠️ Auto-validate: {len(_state.real_issues)} issue(s) "
                        f"(perfect={_state.stats.get('perfect', 0)}/"
                        f"{_state.stats.get('total_chapters', 0)}). See validationIssues.",
                    )

                    # v0.3.18: retry chapters flagged as "Missing MP3"
                    # by re-driving the same `convert_chapter` closure
                    # used by the main loop. Mirrors the CLI's
                    # `_auto_validate_and_retry_async` behaviour but
                    # only retries the missing-MP3 case (duration
                    # outliers and text mismatches need richer logic
                    # the CLI's retry loop already handled inline).
                    # v0.3.20: extended to also retry duration
                    # outliers and duration mismatches. The
                    # median-based duration check (v0.3.15) flags
                    # chapters whose WPM lies outside [50%, 200%] of
                    # the book median — those are usually genuine
                    # synthesis defects (silence padding doubled,
                    # segments duplicated) and a fresh re-synth
                    # often clears them.
                    import re as _re
                    _state._re = _re

                    _state.missing_re = _state._re.compile(r"Chapter\s+([\d.]+):\s+Missing MP3 file")
                    _state.outlier_re = _state._re.compile(
                        r"Chapter\s+([\d.]+):\s+Duration (?:outlier|mismatch)"
                    )
                    _state.missing_labels = {
                        m.group(1) for m in (_state.missing_re.match(i) for i in _state.real_issues) if m
                    }
                    _state.outlier_labels = {
                        m.group(1) for m in (_state.outlier_re.match(i) for i in _state.real_issues) if m
                    }
                    _state.retry_labels = _state.missing_labels | _state.outlier_labels
                    if _state.retry_labels:
                        _state.parts = []
                        if _state.missing_labels:
                            _state.parts.append(f"{len(_state.missing_labels)} missing")
                        if _state.outlier_labels:
                            _state.parts.append(f"{len(_state.outlier_labels)} duration outlier")
                        _runtime._append_event(
                            _state.job,
                            "🔁 Auto-fix: re-synthesising " + " + ".join(_state.parts) + " chapter(s)",
                        )
                        _state.recovered = 0
                        for _state.retry_idx, _state.retry_chapter in enumerate(_state.chapters, start=1):
                            _state.label = str(getattr(_state.retry_chapter, "index", "")).strip()
                            if _state.label not in _state.retry_labels:
                                continue
                            try:
                                await _state.convert_chapter(_state.retry_idx, _state.retry_chapter)
                                if not _state.job_failed["value"]:
                                    _state.recovered += 1
                            except Exception as retry_exc:
                                _state.retry_exc = retry_exc
                                _runtime._append_event(
                                    _state.job,
                                    f"   ↳ retry of {_state.label} failed: {_state.retry_exc}",
                                )
                        if _state.recovered:
                            _runtime._append_event(
                                _state.job,
                                f"✅ Auto-fix: recovered {_state.recovered}/"
                                f"{len(_state.retry_labels)} chapter(s)",
                            )
                            # Re-run validate to update the stats
                            # surfaced through the API.
                            _state.result2 = _state._validate_book(_state.source_path, output_dir=_state.job_output_dir)
                            if _state.result2 is not None:
                                _state.stats2, _state.issues2 = _state.result2
                                _state.job["validationStats"] = _state.stats2
                                _state.job["validationIssues"] = [
                                    i for i in _state.issues2 if "Missing cache" not in i
                                ]
                else:
                    _runtime._append_event(
                        _state.job,
                        f"✅ Auto-validate: all {_state.stats.get('total_chapters', 0)} "
                        "chapter(s) verified against EPUB",
                    )
    except (FileNotFoundError, PermissionError, OSError, ValueError) as exc:
        _state.exc = exc
        _runtime._append_event(_state.job, f"⚠️ Auto-validate skipped: {_state.exc}")
    _runtime._update_job_activity(_state.job, stage="auto_validate_done")

    _runtime._cleanup_output_directory(_state.job_output_dir)
    _runtime._update_job_activity(_state.job, stage="chapters_done")

    if _state._should_abort_current_run("🛑 Conversion cancelled during processing"):
        return _ConversionControl("return", None)
    if _state.job_failed["value"]:
        return _ConversionControl("return", None)
    _state.job["_currentChapterIndex"] = None

    _state.soft_failures: list[dict] = _state.job.get("softFailures") or []
