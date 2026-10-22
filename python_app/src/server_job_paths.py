# -*- coding: utf-8 -*-
"""Validated job identity and confined source/output paths."""

from __future__ import annotations

from pathlib import Path
from typing import Optional


def _book_slug(_runtime, title: Optional[str], fallback: Optional[str] = None) -> str:
    base = title or fallback or "book"
    try:
        stem = _runtime.Path(base).stem if base and "." in base else base
    except Exception:
        stem = base
    return _runtime.FileManager.sanitize_filename(stem)


def _validate_job_id(_runtime, job_id: str) -> None:
    """Raise ValueError if job_id contains path-traversal characters."""
    if not _runtime._VALID_JOB_ID_RE.match(job_id):
        raise ValueError(f"Invalid job_id: {job_id!r}")


def _resolve_path_within_root(_runtime,
    root: Path, candidate: Path | str, *, must_exist: bool = False
) -> Path:
    """Resolve a path and ensure it stays within the provided root directory."""
    root_resolved = root.resolve()
    raw_candidate = _runtime.Path(candidate)
    resolved = (
        raw_candidate.resolve(strict=must_exist)
        if raw_candidate.is_absolute()
        else (root_resolved / raw_candidate).resolve(strict=must_exist)
    )
    if not resolved.is_relative_to(root_resolved):
        raise ValueError(f"Path escapes root: {candidate}")
    return resolved


def _resolve_relative_path_within_root(_runtime,
    root: Path, relative_path: Path | str, *, must_exist: bool = False
) -> Path:
    """Resolve a relative path and ensure it stays inside the provided root."""
    raw_relative = _runtime.Path(relative_path)
    if raw_relative.is_absolute():
        raise ValueError(f"Expected relative path, got: {relative_path}")
    return _runtime._resolve_path_within_root(root, raw_relative, must_exist=must_exist)


def _job_source_roots(_runtime, ) -> tuple[Path, ...]:
    return (_runtime.job_inputs_dir, _runtime.uploads_dir, _runtime.SOURCE_BACKUPS_DIR, _runtime.persistent_root)


def _resolve_job_source_path(_runtime, candidate: Path | str, *, must_exist: bool = False) -> Path:
    last_error: Optional[Exception] = None
    for root in _runtime._job_source_roots():
        try:
            return _runtime._resolve_path_within_root(root, candidate, must_exist=must_exist)
        except Exception as exc:
            last_error = exc
    raise ValueError(f"Invalid job source path: {candidate}") from last_error


def _safe_leaf_name(_runtime, value: str, *, field_name: str) -> str:
    raw = str(value or "")
    name = _runtime.Path(raw).name
    if not name or name != raw:
        raise _runtime.HTTPException(status_code=400, detail=f"Invalid {field_name}")
    return name


def _job_output_dir(_runtime, job_id: str, job: Optional[dict] = None, ensure: bool = False) -> Path:
    """Resolve the canonical output directory for a job.

    The first successful resolution persists the location on the job payload so
    follow-up calls (like streaming endpoints) read/write from the same place.
    When no metadata is available we fallback to the legacy `<output>/<job_id>`
    layout to avoid breaking older jobs.
    """

    _runtime._validate_job_id(job_id)
    legacy_dir = _runtime._resolve_relative_path_within_root(_runtime.output_dir, job_id, must_exist=False)
    job_data = job or _runtime.jobs.get(job_id) or _runtime.job_manager.load_job(job_id)
    target: Optional[Path] = None

    if job_data:
        stored = job_data.get("outputDir")
        if stored:
            try:
                target = _runtime._resolve_path_within_root(_runtime.output_dir, stored, must_exist=False)
            except ValueError:
                target = None
        if target is None:
            book_title = job_data.get("bookTitle") or job_data.get("fileName") or ""
            file_name = job_data.get("file_path") or ""
            book_slug = _runtime._book_slug(book_title, file_name)
            target = _runtime._resolve_relative_path_within_root(_runtime.output_dir, book_slug, must_exist=False)

            # If legacy dir already exists with data, prefer it to avoid breaking older jobs
            if legacy_dir.exists() and any(legacy_dir.iterdir()):
                target = legacy_dir

            job_data["outputDir"] = str(target)
            _runtime.jobs[job_id] = job_data

    if target is None:
        target = legacy_dir

    if ensure:
        target.mkdir(parents=True, exist_ok=True)

    return target


def _job_stream_dir(_runtime, job_id: str, ensure: bool = False) -> Path:
    # Keep the allow-list as the product policy, then normalize and verify the
    # concrete filesystem paths at this boundary. The explicit checks also
    # protect against a pre-existing symlink that points outside the job root.
    _runtime._validate_job_id(job_id)
    base = _runtime._job_output_dir(job_id, ensure=ensure)
    base_path = _runtime.os.path.realpath(_runtime.os.fspath(base))
    streams_root_path = _runtime.os.path.realpath(_runtime.os.path.join(base_path, "streams"))
    if not streams_root_path.startswith(f"{base_path}{_runtime.os.sep}"):
        raise ValueError(f"Invalid job_id: {job_id!r}")
    target_path = _runtime.os.path.realpath(_runtime.os.path.join(streams_root_path, job_id))
    if not target_path.startswith(f"{streams_root_path}{_runtime.os.sep}"):
        raise ValueError(f"Invalid job_id: {job_id!r}")
    target = _runtime.Path(target_path)
    streams_root = target.parent
    if ensure:
        target.mkdir(parents=True, exist_ok=True)
        return target

    if target.exists():
        return target

    # Streams created before per-job isolation lived directly in
    # `<book-output>/streams`. Keep those readable only when the legacy
    # manifest explicitly belongs to this job; sharing a book title must
    # never make one job publish another job's audio chunks.
    legacy_index = streams_root / "index.json"
    if legacy_index.exists():
        try:
            legacy_payload = _runtime.json.loads(legacy_index.read_text(encoding="utf-8"))
        except Exception:
            legacy_payload = None
        if isinstance(legacy_payload, dict) and legacy_payload.get("jobId") == job_id:
            return streams_root

    return target
