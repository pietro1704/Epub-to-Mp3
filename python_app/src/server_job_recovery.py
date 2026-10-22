# -*- coding: utf-8 -*-
"""Recover existing outputs and summarize recent jobs."""

from __future__ import annotations

from pathlib import Path
from typing import Optional


def _normalize_book_title(_runtime, value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    cleaned = _runtime.re.sub(r"[_\-]+", " ", value)
    cleaned = _runtime.re.sub(r"\s+", " ", cleaned).strip()
    return cleaned or None


def _safe_file_size(_runtime, path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def _guess_image_mime(_runtime, suffix: str) -> str:
    lowered = suffix.lower()
    if lowered in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if lowered == ".png":
        return "image/png"
    if lowered == ".webp":
        return "image/webp"
    if lowered == ".gif":
        return "image/gif"
    return "application/octet-stream"


def _find_cover_asset(_runtime, job_output_dir: Path) -> Optional[Path]:
    preferred_names = [
        "cover.jpg",
        "cover.jpeg",
        "cover.png",
        "cover.webp",
    ]
    for name in preferred_names:
        candidate = job_output_dir / name
        if candidate.exists():
            return candidate

    for suffix in (".jpg", ".jpeg", ".png", ".webp"):
        for candidate in job_output_dir.glob(f"*{suffix}"):
            if candidate.is_file():
                return candidate
    return None


def _locate_job_output_dir_for_recovery(_runtime, job_id: str) -> Optional[Path]:
    legacy_dir = _runtime.output_dir / job_id
    if legacy_dir.exists():
        return legacy_dir

    try:
        for streams_dir in _runtime.output_dir.rglob("streams"):
            if not streams_dir.is_dir():
                continue
            candidate = streams_dir / job_id
            if candidate.exists():
                return streams_dir.parent
    except Exception as exc:
        _runtime.logger.warning("Failed to scan outputs for job %s: %s", job_id, exc)
    return None


def _restore_job_from_outputs(_runtime, job_id: str) -> Optional[dict]:
    """Rebuild a finished job if metadata was lost, based on existing outputs."""
    job_output_dir = _runtime._locate_job_output_dir_for_recovery(job_id)
    if not job_output_dir or not job_output_dir.exists():
        return None

    mp3_files = sorted(p for p in job_output_dir.glob("*.mp3") if p.is_file())
    zip_files = sorted(p for p in job_output_dir.glob("*.zip") if p.is_file())
    log_path = job_output_dir / "conversion.log"
    has_log = log_path.exists()

    if not mp3_files and not zip_files and not has_log:
        return None

    def _asset_entry(path: Path) -> dict:
        entry: dict = {
            "name": path.name,
            "url": f"/api/outputs/{job_id}/{path.name}",
            "sizeBytes": _runtime._safe_file_size(path),
        }
        # Only MP3 chapters carry an SHA-256 (clients verify chapter audio,
        # not zips/logs).  Failures are silently skipped — the field is
        # optional for the iOS client.
        if path.suffix.lower() == ".mp3":
            with _runtime.contextlib.suppress(Exception):
                from src._server_audio_helpers import compute_mp3_sha256

                entry["sha256"] = compute_mp3_sha256(path)
        return entry

    outputs: list[dict] = []
    for zip_path in zip_files:
        outputs.append(_asset_entry(zip_path))
    if has_log:
        outputs.append(_asset_entry(log_path))
    for mp3_path in mp3_files:
        outputs.append(_asset_entry(mp3_path))
    outputs = _runtime._sort_output_entries(outputs)

    book_title = _runtime._normalize_book_title(zip_files[0].stem if zip_files else None)
    if not book_title:
        parent_name = job_output_dir.parent.name if job_output_dir.parent else None
        fallback = _runtime._normalize_book_title(parent_name) or _runtime._normalize_book_title(job_id)
        book_title = fallback or "Livro Desconhecido"

    def _restore_chapter_entry(idx: int, path: Path) -> dict:
        # Strip the "NNN - " numeric prefix that FileManager.sanitize_filename
        # prepends during conversion so the iOS client sees "Chapter Title"
        # rather than "001 - Chapter Title" (or a sanitised hash).
        stem = path.stem
        # Strip the "NNN - " numeric prefix added by FileManager.sanitize_filename
        # (format: "{index:03d} - {safe_name}").  Require at least one space on
        # each side of the dash so we never strip hyphens inside real titles
        # (e.g. "42-Plain" would be kept intact).
        human_name = _runtime.re.sub(r"^\d+\s+[-–]\s+", "", stem).strip() or stem
        entry: dict = {
            "index": idx,
            "name": human_name,
            "status": "completed",
            "downloadUrl": f"/api/outputs/{job_id}/{path.name}",
        }
        # Mirror the per-MP3 SHA-256 published in the outputs list so the
        # iOS client can verify chapter downloads after a restore.
        with _runtime.contextlib.suppress(Exception):
            from src._server_audio_helpers import compute_mp3_sha256

            entry["sha256"] = compute_mp3_sha256(path)
        return entry

    chapter_progress = [_restore_chapter_entry(idx, path) for idx, path in enumerate(mp3_files)]

    timestamps: list[float] = []
    for path in mp3_files + zip_files:
        with _runtime.contextlib.suppress(OSError):
            timestamps.append(path.stat().st_mtime)
    if has_log:
        with _runtime.contextlib.suppress(OSError):
            timestamps.append(log_path.stat().st_mtime)
    completed_ts = max(timestamps) if timestamps else _runtime.time.time()
    completed_iso = _runtime.datetime.fromtimestamp(completed_ts, tz=_runtime.timezone.utc).isoformat()

    cover_entry = None
    cover_path = _runtime._find_cover_asset(job_output_dir)
    if cover_path:
        cover_entry = {
            "name": cover_path.name,
            "url": f"/api/outputs/{job_id}/{cover_path.name}",
            "mimeType": _runtime._guess_image_mime(cover_path.suffix),
        }

    job_data = {
        "jobId": job_id,
        "state": "finished",
        "events": [
            "♻️ Conversion restored from already saved files",
            "📦 Downloads available - metadata reconstructed automatically",
        ],
        "_raw_log": [],
        "outputs": outputs,
        "outputDir": str(job_output_dir),
        "bookTitle": book_title,
        "bookAuthor": None,
        "engine": job_output_dir.name,
        "voice": None,
        "language": None,
        "progressPercent": 100.0,
        "chaptersCompleted": len(mp3_files),
        "chaptersTotal": len(mp3_files),
        "chapterProgress": chapter_progress,
        "cover": cover_entry,
        "coverUrl": cover_entry["url"] if cover_entry else None,
        "coverMimeType": cover_entry["mimeType"] if cover_entry else None,
        "logUrl": f"/api/outputs/{job_id}/{log_path.name}" if has_log else None,
        "cancelRequested": False,
        "resumeRequested": False,
        "parallelActive": 0,
        "createdAt": completed_iso,
        "startedAt": completed_iso,
        "completedAt": completed_ts,
        "completedAtIso": completed_iso,
        "_lastActivityTs": completed_ts,
        "totalElapsedSeconds": None,
    }
    if cover_entry is None:
        job_data["cover"] = None
    job_data["_raw_log"] = list(job_data["events"])
    return job_data


def _resolve_job_activity_timestamp(_runtime, job_data: dict) -> Optional[float]:
    ts = job_data.get("_lastActivityTs")
    if isinstance(ts, (int, float)):
        return float(ts)
    started_at = job_data.get("startedAt")
    if started_at:
        try:
            return _runtime.datetime.fromisoformat(started_at.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


def _summarize_recent_job(_runtime, job_id: str, job_data: dict, saved_at: Optional[str] = None) -> dict:
    outputs = job_data.get("outputs") or []
    zip_asset = None
    for asset in outputs:
        name = (asset.get("name") or "").lower()
        if name.endswith(".zip"):
            zip_asset = asset
            break
    resume_states = {"queued", "running", "cancelling"}
    completed_iso = _runtime._resolve_completed_iso(job_data)
    saved_value = saved_at or _runtime._determine_saved_at(job_data)
    return {
        "jobId": job_id,
        "state": job_data.get("state", "unknown"),
        "bookTitle": job_data.get("bookTitle", "Livro Desconhecido"),
        "fileName": _runtime.Path(job_data.get("file_path", "")).name
        if job_data.get("file_path")
        else "unknown",
        "savedAt": saved_value,
        "chaptersCompleted": job_data.get("chaptersCompleted"),
        "chaptersTotal": job_data.get("chaptersTotal"),
        "progressPercent": job_data.get("progressPercent"),
        "downloadUrl": zip_asset.get("url") if zip_asset else None,
        "hasOutputs": bool(outputs),
        "canResume": job_data.get("state") in resume_states,
        "outputs": outputs,
        "engine": job_data.get("engine"),
        "voice": job_data.get("voice"),
        "language": job_data.get("detectedLanguage") or job_data.get("language"),
        "formattingCues": job_data.get("formattingCues"),
        "uiLanguage": job_data.get("uiLanguage"),
        "completedAt": completed_iso or saved_value,
        "startedAt": job_data.get("startedAt"),
        "totalDurationSeconds": job_data.get("totalElapsedSeconds"),
    }


def _collect_recent_job_entries(_runtime, limit: int = 10) -> list[dict]:
    """**OPTIMIZED**: Uses in-memory index to avoid reading ALL jobs from disk.

    Old approach: O(n) disk reads for n jobs
    New approach: O(1) index lookup + O(limit) disk reads for top jobs only
    """
    # **OPTIMIZATION #1**: Sort by index first (no disk I/O)
    sorted_job_ids = sorted(
        _runtime._recent_jobs_index.keys(),
        key=lambda jid: _runtime._recent_jobs_index[jid][0],  # Sort by savedAt timestamp
        reverse=True,
    )

    # **OPTIMIZATION #1**: Only load top `limit` jobs
    summaries: list[dict] = []
    for job_id in sorted_job_ids[:limit]:
        # Check in-memory jobs first
        if job_id in _runtime.jobs:
            job_data = _runtime.jobs[job_id]
            saved_at = _runtime._determine_saved_at(job_data)
        else:
            # Fall back to disk/cache (rare)
            job_data = _runtime.job_manager.load_job(job_id)
            if not job_data:
                continue
            saved_at = _runtime._determine_saved_at(job_data)

        if (job_data.get("state") or "").lower() == "cancelled":
            continue

        summaries.append(_runtime._summarize_recent_job(job_id, job_data, saved_at=saved_at))

    return summaries
