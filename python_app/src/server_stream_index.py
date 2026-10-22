# -*- coding: utf-8 -*-
"""Atomic stream manifests and retired-chunk bookkeeping."""

from __future__ import annotations

from pathlib import Path


def _stream_index_path(_runtime, job_id: str, ensure: bool = False) -> Path:
    stream_dir = _runtime._job_stream_dir(job_id, ensure=ensure)
    return stream_dir / "index.json"


def _load_stream_index(_runtime, job_id: str) -> dict:
    index_path = _runtime._stream_index_path(job_id, ensure=False)
    if not index_path.exists():
        return {"chapters": {}}
    try:
        payload = _runtime.json.loads(index_path.read_text(encoding="utf-8"))
    except Exception:
        return {"chapters": {}}
    if not isinstance(payload, dict):
        return {"chapters": {}}
    chapters = payload.get("chapters")
    if not isinstance(chapters, dict):
        payload["chapters"] = {}
    return payload


def _atomic_write_text(_runtime, path: Path, data: str, encoding: str = "utf-8") -> None:
    """Write `data` to `path` via a sibling tmp file + `os.replace`.

    A direct `Path.write_text` (or `open(path, "w")`) is non-atomic: a
    SIGTERM, ENOMEM or disk-full landing mid-write leaves the target
    file half-written, so the next reader sees a JSON parse error and
    treats persisted state as lost. `os.replace` is atomic on POSIX and
    atomic-since-3.3 on Windows: either the new bytes are fully in
    place, or the previous bytes (or non-existence) are still there.
    fsync the fd before the rename so the bytes are durable on disk
    before the swap is published; PID-suffixed tmp filename keeps
    concurrent writers from clobbering each other's in-flight stream.
    On any failure the tmp file is unlinked so the parent directory
    never accumulates `*.tmp` orphans.
    """
    tmp_path = path.with_suffix(path.suffix + f".{_runtime.os.getpid()}.tmp")
    try:
        with open(tmp_path, "w", encoding=encoding) as handle:
            handle.write(data)
            handle.flush()
            _runtime.os.fsync(handle.fileno())
        _runtime.os.replace(tmp_path, path)
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def _retired_stream_chunks(_runtime, chapter: object, active_ids: frozenset[str] = frozenset()) -> list[dict]:
    """Preserve valid publication aliases without carrying corrupt history forward."""
    if not isinstance(chapter, dict):
        return []
    retired: dict[str, dict] = {}
    for field in ("retiredChunks", "chunks"):
        entries = chapter.get(field)
        if not isinstance(entries, list):
            continue
        for chunk in entries:
            if not isinstance(chunk, dict):
                continue
            chunk_id = chunk.get("id")
            filename = chunk.get("file")
            if isinstance(chunk_id, bool) or not isinstance(chunk_id, (str, int)):
                continue
            identity = str(chunk_id)
            if not identity or not all(char.isalnum() or char in "_-" for char in identity):
                continue
            if not isinstance(filename, str) or not filename or filename in (".", ".."):
                continue
            if any(char in filename for char in ("/", "\\", "\0")) or identity in active_ids:
                continue
            retired[identity] = {"id": chunk_id, "file": filename}
    return list(retired.values())


def _save_stream_index(_runtime, job_id: str, payload: dict) -> None:
    index_path = _runtime._stream_index_path(job_id, ensure=True)
    payload.setdefault("chapters", {})
    _runtime._atomic_write_text(
        index_path,
        _runtime.json.dumps(payload, ensure_ascii=False, indent=2),
    )
