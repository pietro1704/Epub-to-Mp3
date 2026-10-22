# -*- coding: utf-8 -*-
"""Downloadable outputs and streaming manifest/chunk responses."""

from __future__ import annotations

from typing import Optional

from fastapi import Request
from fastapi.responses import FileResponse


async def download_output(_runtime, job_id: str, filename: str) -> FileResponse:
    _runtime._validate_job_id(job_id)
    job_data = _runtime.jobs.get(job_id) or _runtime.job_manager.load_job(job_id)
    base_dir = _runtime._job_output_dir(job_id, job_data).resolve()
    safe_filename = _runtime._safe_leaf_name(filename, field_name="filename")
    legacy_base = _runtime._resolve_relative_path_within_root(_runtime.output_dir, job_id, must_exist=False)
    file_path: Optional[_runtime.Path] = None
    output_prefix = _runtime.os.path.realpath(_runtime.output_dir).rstrip(_runtime.os.sep) + _runtime.os.sep

    for candidate_root in (base_dir, legacy_base):
        try:
            matches = sorted(
                path
                for path in candidate_root.rglob("*")
                if path.name == safe_filename
            )
        except OSError:
            continue
        for candidate in matches:
            try:
                resolved = _runtime._resolve_path_within_root(candidate_root, candidate, must_exist=True)
                # Retain the book boundary and independently require the trusted output root.
                resolved_path = _runtime.os.path.realpath(resolved)
                if not resolved_path.startswith(output_prefix):
                    continue
                if not _runtime.Path(resolved_path).is_file():
                    continue
            except (OSError, RuntimeError, ValueError):
                continue
            file_path = _runtime.Path(resolved_path)
            break
        if file_path is not None:
            break

    if file_path is None:
        raise _runtime.HTTPException(status_code=404, detail="File not found")
    return _runtime.FileResponse(
        path=file_path,
        media_type=_runtime._guess_media_type(safe_filename),
        filename=safe_filename,
    )


async def stream_manifest(_runtime, job_id: str, chapter_index: int) -> dict:
    """Return available chunk list for a chapter."""
    _runtime._validate_job_id(job_id)
    index_payload = _runtime._load_stream_index(job_id)
    chapter_key = str(int(chapter_index))
    chapter_payload = index_payload.get("chapters", {}).get(chapter_key) or {}
    base_url = f"/api/streams/{job_id}/chapters/{chapter_index}"
    chunks = chapter_payload.get("chunks") or []

    return {
        "jobId": job_id,
        "chapterIndex": int(chapter_index),
        "baseUrl": base_url,
        "chunks": chunks,
        "updatedAt": chapter_payload.get("updatedAt") or _runtime.time.time(),
    }


async def stream_chunk(_runtime, job_id: str, chapter_index: int, chunk_id: str, request: Request):
    """Serve an individual synthesized chunk for progressive playback."""
    import re as _re

    journey_headers = request.headers.getlist("X-Playback-Journey-ID")
    received_at = _runtime.stream_http_observations.received_at() if journey_headers else None
    journey_id = None
    if journey_headers:
        try:
            if len(journey_headers) != 1:
                raise ValueError("Duplicate playback journey IDs")
            journey_id = _runtime.validate_journey_id(journey_headers[0])
        except ValueError:
            raise _runtime.HTTPException(status_code=422, detail="Invalid playback journey ID") from None

    _runtime._validate_job_id(job_id)
    if not _re.match(r"^[\w\-]+$", chunk_id):
        raise _runtime.HTTPException(status_code=400, detail="Invalid chunk ID")
    stream_dir = _runtime._job_stream_dir(job_id, ensure=False).resolve()
    if not stream_dir.exists():
        raise _runtime.HTTPException(status_code=404, detail="Chunk not found")

    index_payload = _runtime._load_stream_index(job_id)
    chapter_payload = index_payload.get("chapters", {}).get(str(int(chapter_index))) or {}
    publications = (chapter_payload.get("chunks") or []) + (
        chapter_payload.get("retiredChunks") or []
    )
    chunk_entry = next(
        (item for item in publications if str(item.get("id")) == chunk_id),
        None,
    )
    if chunk_entry is None:
        raise _runtime.HTTPException(status_code=404, detail="Chunk not found")

    # Build the served file from a strictly-validated allow-list of basenames
    # already present on disk inside `stream_dir`. The manifest's `file`
    # field is treated as untrusted: we only use it to look up an entry,
    # never to construct the served path. This pattern (compare against an
    # enumerated set of safe paths) is the canonical anti-path-injection
    # form recognised by CodeQL's taint analysis.
    requested_basename = _runtime.Path(str(chunk_entry.get("file") or "")).name
    if not requested_basename:
        raise _runtime.HTTPException(status_code=400, detail="Invalid chunk")
    allowed_files = {entry.name: entry for entry in stream_dir.iterdir() if entry.is_file()}
    served_entry = allowed_files.get(requested_basename)
    if served_entry is None:
        raise _runtime.HTTPException(status_code=404, detail="Chunk not found")

    response = _runtime.FileResponse(
        path=served_entry,
        media_type=_runtime._guess_media_type(served_entry.name),
    )
    if journey_id is None:
        return response
    return _runtime.ObservedFileResponse(
        response, _runtime.stream_http_observations, journey_id, chunk_id, received_at=received_at
    )


async def download_sample_epub(_runtime, ):
    """Serve bundled sample EPUB for quick testing via frontend."""
    for candidate in _runtime.SAMPLE_BOOK_CANDIDATES:
        if candidate.exists():
            return _runtime.FileResponse(
                str(candidate),
                media_type="application/epub+zip",
                filename="sample.epub",
            )
    raise _runtime.HTTPException(status_code=404, detail="Sample EPUB unavailable")
