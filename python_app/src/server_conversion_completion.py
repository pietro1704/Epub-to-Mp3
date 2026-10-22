# -*- coding: utf-8 -*-
"""Server conversion completion."""

from __future__ import annotations


from .conversion_control import ConversionControl as _ConversionControl


async def _server_conversion_completion(_runtime, _state):
    if _state.soft_failures:
        _state.job["softFailureCount"] = len(_state.soft_failures)
        _state.preview = ", ".join(
            f"#{entry.get('index')} {entry.get('chapter')}"
            for entry in _state.soft_failures[:3]
            if isinstance(entry, dict)
        )
        if len(_state.soft_failures) > 3:
            _state.preview += f" … (+{len(_state.soft_failures) - 3})"
        _state.summary_line = (
            f"⚠️ {len(_state.soft_failures)} chapter(s) failed and were skipped automatically."
        )
        if _state.preview:
            _state.summary_line += f" ({_state.preview})"
        _runtime._append_event(_state.job, _state.summary_line)

    if _state.zip_open:
        with _runtime.contextlib.suppress(Exception):
            _state.zip_archive.close()
        _state.zip_open = False

    # Rebuild ZIP to include all available chapters (including resumed ones)
    _runtime._append_event(_state.job, "📦 Packing chapters into final ZIP...")
    _runtime._update_job_activity(_state.job, stage="building_zip")
    _runtime._persist_job(_state.job_id, force=True)
    try:
        with _runtime.zipfile.ZipFile(_state.zip_file, "w", _runtime.zipfile.ZIP_STORED) as _state.rebuilt_zip:
            for _state.mp3_path in sorted(_state.job_output_dir.glob("*.mp3")):
                if _state.mp3_path.name.lower().startswith("tmp"):
                    continue
                _state.rebuilt_zip.write(_state.mp3_path, arcname=_state.mp3_path.name)
        _runtime._append_event(_state.job, "✅ Final ZIP ready")
    except Exception as exc:
        _state.exc = exc
        _runtime._append_event(_state.job, f"⚠️ Failed to pack ZIP: {_state.exc}")

    # Update outputs table with existing files (deduplicate by name)
    _state.outputs_map: dict[str, dict] = {}
    for _state.asset in _state.outputs:
        _state.outputs_map[_state.asset["name"]] = _state.asset
    for _state.mp3_path in sorted(_state.job_output_dir.glob("*.mp3")):
        if _state.mp3_path.name.lower().startswith("tmp"):
            continue
        _state.name = _state.mp3_path.name
        _state.entry = _state.outputs_map.get(_state.name)
        if not _state.entry:
            _state.entry = {
                "name": _state.name,
                "url": f"/api/outputs/{_state.job_id}/{_state.name}",
            }
            _state.outputs_map[_state.name] = _state.entry
        _state.entry["sizeBytes"] = _state.mp3_path.stat().st_size
        # SHA-256 for client-side chapter download verification.
        if "sha256" not in _state.entry:
            with _runtime.contextlib.suppress(Exception):
                from src._server_audio_helpers import compute_mp3_sha256
                _state.compute_mp3_sha256 = compute_mp3_sha256

                _state.entry["sha256"] = _state.compute_mp3_sha256(_state.mp3_path)
    _state.outputs = list(_state.outputs_map.values())
    _runtime._update_job_activity(_state.job, stage="outputs_ready")

    _state.cover_entry = _state.job.get("cover")
    _state.upload_dir_path = _runtime.Path(_state.job.get("uploadDir") or "")
    if _state.cover_entry and _state.cover_entry.get("name") and _state.upload_dir_path.exists():
        _state.source_cover = _state.upload_dir_path / _state.cover_entry["name"]
        _state.dest_cover = _state.job_output_dir / _state.cover_entry["name"]
        if _state.source_cover.exists():
            with _runtime.contextlib.suppress(Exception):
                _runtime.shutil.copy2(_state.source_cover, _state.dest_cover)
                _state.cover_entry["url"] = f"/api/outputs/{_state.job_id}/{_state.cover_entry['name']}"
                _state.job["coverUrl"] = _state.cover_entry["url"]

    # Local storage - files are served from local output directory
    _state.zip_url = f"/api/outputs/{_state.job_id}/{_state.zip_file.name}"

    _state.outputs.insert(
        0,
        {
            "name": _state.zip_file.name,
            "url": _state.zip_url,
            "sizeBytes": _state.zip_file.stat().st_size,
        },
    )

    _state.log_path = _runtime._persist_job_log(_state.job_id, _state.job)
    if _state.log_path and _state.log_path.exists():
        _state.log_entry = {
            "name": _state.log_path.name,
            "url": f"/api/outputs/{_state.job_id}/{_state.log_path.name}",
            "sizeBytes": _state.log_path.stat().st_size,
        }
        _state.insert_index = 1 if _state.outputs else 0
        _state.outputs.insert(_state.insert_index, _state.log_entry)
        if _state.zip_open:
            try:
                _state.zip_archive.write(_state.log_path, arcname=_state.log_path.name)
            except Exception:
                pass

    _state.total_elapsed = _runtime.time.time() - _state.conversion_started

    # iPhone export (v0.3.20): per-job opt-in via the form, with the
    # EXPORT_TO_IPHONE env var as a fallback for users who set it
    # globally on the desktop sidecar. macOS-only; failures are
    # informational and never fail the job.
    if _state.job.get("exportToIphone") or _runtime.os.environ.get("EXPORT_TO_IPHONE", "").lower() in {
        "1",
        "true",
        "yes",
        "on",
    }:
        try:
            from src.iphone_export import export_book_to_iphone, is_macos
            _state.export_book_to_iphone = export_book_to_iphone
            _state.is_macos = is_macos

            if _state.is_macos():
                _state.book_title_for_export = (
                    _state.job.get("bookTitle") or _state.job_output_dir.name or "Audiobook"
                )
                _state.ok, _state.error = _state.export_book_to_iphone(
                    _state.job_output_dir,
                    book_title=_state.book_title_for_export,
                    log=lambda msg: _runtime._append_event(_state.job, msg),
                )
                if not _state.ok:
                    _runtime._append_event(_state.job, f"⚠️ iPhone export skipped: {_state.error}")
            else:
                _runtime._append_event(
                    _state.job,
                    "⚠️ iPhone export requires macOS — skipping (Linux/Windows host).",
                )
        except Exception as exc:
            _state.exc = exc
            _runtime._append_event(_state.job, f"⚠️ iPhone export raised unexpectedly: {_state.exc}")

    _state.job["state"] = "finished"
    _state.job["progressPercent"] = 100
    _state.job["outputs"] = _runtime._sort_output_entries(_state.outputs)
    _state.job["completedAt"] = _runtime.time.time()  # Timestamp for cleanup
    _state.job["completedAtIso"] = _runtime._utcnow_iso()
    _state.job["totalElapsedSeconds"] = int(_state.total_elapsed)
    _runtime._update_job_activity(_state.job, stage="completed_success")

    # Persistent conversion session log
    try:
        from src.session_logger import log_session
        _state.log_session = log_session

        _state._ch_total = _state.job.get("chaptersTotal") or 0
        _state._cp = _state.job.get("chapterProgress") or []
        if _state._cp:
            _state._ch_done = sum(1 for c in _state._cp if c.get("status") == "completed")
            _state._ch_failed = sum(1 for c in _state._cp if c.get("status") in {"failed", "skipped"})
        else:
            _state._ch_done = _state.job.get("chaptersCompleted") or 0
            _state._ch_failed = _state._ch_total - _state._ch_done
        _state._chapter_details = _runtime._extract_chapter_details(_state.job)
        # Mirrors the CLI's `errors` trace field (main.py) — the job can
        # reach "finished" with lingering validationIssues (see the
        # auto-validate block above), and without this the log can't
        # explain a "success" outcome that's actually incomplete.
        _state._validation_issues = _state.job.get("validationIssues")
        _state.log_session(
            book_title=_state.job.get("bookTitle", ""),
            book_author=_state.job.get("bookAuthor", ""),
            language=_state.job.get("detectedLanguage", ""),
            engine=_state.job.get("engine", ""),
            voice=_state.job.get("voice", ""),
            chapters_total=_state._ch_total,
            chapters_converted=_state._ch_done,
            chapters_failed=_state._ch_failed,
            duration_seconds=_state.total_elapsed,
            outcome="success",
            job_id=_state.job_id,
            output_dir=str(_state.job.get("outputDir", "")),
            started_at=_state.job.get("startedAt", ""),
            chapter_details=_state._chapter_details or None,
            extra={"validationIssues": _state._validation_issues[:20]} if _state._validation_issues else None,
        )
    except Exception:
        pass  # Never let logging break a conversion
    _runtime._append_event(_state.job, "")
    _runtime._append_event(_state.job, "✅ Conversion completed successfully")
    _runtime._append_event(_state.job, f"⏱️ Total conversion time: {_runtime.TimeFormatter.format_time(_state.total_elapsed)}")
    _runtime._append_event(_state.job, f"📁 File available: {_state.zip_file.name} ({len(_state.chapters)} chapters)")
    _state.job["parallelActive"] = 0
    _state.job["resumeRequested"] = False
    _runtime._persist_job(_state.job_id)

    # **CRITICAL**: Ensure final broadcast so frontend transitions to step 3
    _runtime._schedule_job_broadcast(_state.job_id, _state.job)

    if _state.job.get("_purgeRequested"):
        _runtime._purge_job_data(_state.job_id, _state.job)
        return _ConversionControl("return", None)

    # KEEP job in memory and disk for at least 1 hour after completion
    # This prevents 404 errors when frontend is still polling
    # Jobs will be cleaned up by periodic cleanup task
    _runtime.logger.info(f"Job {_state.job_id} completed successfully - keeping in memory for frontend access")
