# -*- coding: utf-8 -*-
"""Pending upload retention and chapter-limit validation."""

from __future__ import annotations

from pathlib import Path
from typing import List, Optional


def _env_float(_runtime, name: str, default: float) -> float:
    raw = _runtime.os.getenv(name, "")
    try:
        return float(raw) if raw else default
    except (TypeError, ValueError):
        return default


def _env_int(_runtime, name: str, default: int) -> int:
    raw = _runtime.os.getenv(name, "")
    try:
        return int(raw) if raw else default
    except (TypeError, ValueError):
        return default


def _resolve_max_chapter_limit(_runtime, ) -> int:
    """Return the max number of chapters allowed per job (0 = sem limite)."""
    env_limit = _runtime.os.getenv("MAX_CHAPTERS_PER_JOB")
    if env_limit:
        try:
            return max(0, int(env_limit))
        except (TypeError, ValueError):
            _runtime.logger.warning("Invalid MAX_CHAPTERS_PER_JOB value: %s", env_limit)
    return 0


def _cleanup_pending_uploads(_runtime, ) -> None:
    cutoff = _runtime.time.time() - _runtime._PENDING_TTL_SECONDS
    expired: List[str] = []
    with _runtime._pending_lock:
        for upload_id, entry in list(_runtime._pending_uploads.items()):
            if entry.get("created_at", 0) < cutoff:
                expired.append(upload_id)
                _runtime._pending_uploads.pop(upload_id, None)
        active_ids = set(_runtime._pending_uploads.keys())
    for upload_dir in _runtime.uploads_dir.iterdir():
        if not upload_dir.is_dir():
            continue
        upload_id = upload_dir.name
        if upload_id in active_ids:
            continue
        meta_path = upload_dir / _runtime._PENDING_META_FILENAME
        created_at = None
        if meta_path.exists():
            try:
                created_at = _runtime.json.loads(meta_path.read_text()).get("created_at")
            except Exception:
                created_at = None
        if created_at is None:
            try:
                created_at = upload_dir.stat().st_mtime
            except OSError:
                created_at = None
        if created_at is not None and created_at < cutoff:
            expired.append(upload_id)
    for upload_id in expired:
        upload_dir = _runtime.uploads_dir / upload_id
        if upload_dir.exists():
            _runtime.shutil.rmtree(upload_dir, ignore_errors=True)


def _write_pending_upload_metadata(_runtime, upload_dir: Path, data: dict) -> None:
    payload = {
        "file_name": data.get("file_name"),
        "book_title": data.get("book_title"),
        "book_author": data.get("book_author"),
        "cover_filename": data.get("cover_filename"),
        "cover_mime": data.get("cover_mime"),
        "file_hash": data.get("file_hash"),
        "created_at": data.get("created_at"),
    }
    try:
        (upload_dir / _runtime._PENDING_META_FILENAME).write_text(_runtime.json.dumps(payload))
    except Exception:
        pass


def _load_pending_upload_from_disk(_runtime, upload_id: str) -> Optional[dict]:
    upload_dir = _runtime.uploads_dir / upload_id
    if not upload_dir.exists():
        return None
    meta_path = upload_dir / _runtime._PENDING_META_FILENAME
    payload: dict = {}
    if meta_path.exists():
        try:
            payload = _runtime.json.loads(meta_path.read_text())
        except Exception:
            payload = {}
    cover_filename = payload.get("cover_filename")
    cover_path = upload_dir / cover_filename if cover_filename else None
    if cover_path and not cover_path.exists():
        cover_path = None

    file_name = payload.get("file_name")
    candidate = None
    if file_name:
        candidate = upload_dir / _runtime.Path(file_name).name
        if not candidate.exists():
            candidate = None
    if candidate is None:
        for path in upload_dir.iterdir():
            if not path.is_file():
                continue
            if path.name == _runtime._PENDING_META_FILENAME:
                continue
            if cover_filename and path.name == cover_filename:
                continue
            candidate = path
            break
    if candidate is None or not candidate.exists():
        return None

    created_at = payload.get("created_at")
    if created_at is None:
        try:
            created_at = candidate.stat().st_mtime
        except OSError:
            created_at = _runtime.time.time()

    return {
        "file_path": str(candidate),
        "file_name": file_name or candidate.name,
        "book_title": payload.get("book_title"),
        "book_author": payload.get("book_author"),
        "cover_filename": cover_filename,
        "cover_path": str(cover_path) if cover_path else None,
        "cover_mime": payload.get("cover_mime"),
        "file_hash": payload.get("file_hash"),
        "created_at": created_at,
    }


def _enforce_chapter_limit(_runtime, chapter_count: int) -> None:
    if _runtime.MAX_CHAPTERS_PER_JOB and chapter_count > _runtime.MAX_CHAPTERS_PER_JOB:
        _runtime.logger.warning(
            "Job rejected: %s chapters exceeds limit of %s",
            chapter_count,
            _runtime.MAX_CHAPTERS_PER_JOB,
        )
        raise _runtime.HTTPException(
            status_code=413,
            detail=(
                f"This book has {chapter_count} chapters but the current limit is "
                f"{_runtime.MAX_CHAPTERS_PER_JOB}. Upload smaller excerpts or select fewer chapters."
            ),
        )
