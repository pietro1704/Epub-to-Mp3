# -*- coding: utf-8 -*-
"""Canonical chapter labels, output deduplication and job logs."""

from __future__ import annotations

from pathlib import Path
from typing import Optional


def _chapter_display_name(_runtime, name: Optional[str], html: Optional[str], index: int) -> str:
    """Return the canonical TOC/heading title emitted to every client surface."""
    candidate = _runtime.TextProcessor.clean_chapter_title((name or "").strip())
    normalized = _runtime.re.sub(r"\s+", " ", candidate).strip().casefold()
    generic = normalized in {"chapter", "capitulo", "capítulo"} or bool(
        _runtime.re.fullmatch(r"(?:chapter|cap[ií]tulo)\s+\d+", normalized)
    )
    if not generic and candidate:
        return candidate
    heading = _runtime.TextProcessor.extract_first_heading(html)
    if heading:
        heading = _runtime.TextProcessor.clean_chapter_title(heading)
        if heading:
            return heading
    return candidate or f"Chapter {index}"


def _server_dedup_chapter_outputs(_runtime, output_dir: Path) -> int:
    """Collapse duplicate MP3s sharing a `<label> - ` prefix.

    Mirror of `_ValidationMixin._dedup_chapter_outputs` from
    `_validation_mixin.py` — the CLI runs that during its post-conversion
    auto-fix; the server skipped the step until v0.3.17 and accumulated
    duplicates over multiple runs of the same book. Keeps the file with
    the longest audio duration (ffprobe-measured), falls back to file
    size when ffprobe fails. Returns the number of files removed.
    """
    import re as _re
    import subprocess as _subprocess
    from collections import defaultdict as _defaultdict

    if not output_dir or not output_dir.exists():
        return 0

    label_re = _re.compile(r"^([\d.]+)\s+-\s+")
    groups: dict[str, list[Path]] = _defaultdict(list)
    for mp3 in output_dir.glob("*.mp3"):
        match = label_re.match(mp3.name)
        if not match:
            continue
        groups[match.group(1)].append(mp3)

    def _duration(path: Path) -> float:
        try:
            out = _subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(path),
                ],
                capture_output=True,
                text=True,
                timeout=15,
            )
            return float(out.stdout.strip() or 0.0)
        except Exception:
            # ffprobe missing or refused the file — fall back to file
            # size as a proxy for "more content". Better than skipping
            # the dedup entirely and leaving phantom dups for the
            # validator to flag.
            return 0.0

    removed = 0
    for label, files in groups.items():
        if len(files) <= 1:
            continue
        scored = [(_duration(f), f.stat().st_size, f) for f in files]
        scored.sort(key=lambda t: (t[0], t[1]), reverse=True)
        for _dur, _size, loser in scored[1:]:
            try:
                loser.unlink()
                removed += 1
            except OSError:
                pass
    return removed


def _has_kokoro_support(_runtime, language: Optional[str]) -> bool:
    """Stub kept for test back-compat after the Kokoro engine was removed.
    Always returns False — Kokoro TTS is no longer available."""
    return False


def _has_piper_support(_runtime, ) -> bool:
    return _runtime._PIPER_SUPPORTED


def _has_spark_support(_runtime, ) -> bool:
    """Stub kept for test back-compat after the Spark engine was removed.
    Always returns False — Spark TTS is no longer available."""
    return False


def _has_coqui_support(_runtime, ) -> bool:
    """Stub kept for test back-compat after the Coqui engine was removed.
    Always returns False — Coqui TTS is no longer available."""
    return False


def _store_cover_in_cache(_runtime, file_hash: Optional[str], cover_blob) -> Optional[Path]:
    if not file_hash or not cover_blob:
        return None
    filename = f"{file_hash}{cover_blob.extension}"
    cache_path = _runtime.cover_cache_dir / filename
    try:
        cache_path.write_bytes(cover_blob.data)
        _runtime.cover_cache_index[file_hash] = {
            "filename": filename,
            "mime": cover_blob.media_type,
        }
        _runtime._save_cover_cache(_runtime.cover_cache_index)
        return cache_path
    except Exception:
        return None


def _should_retry_edge_before_fallback(_runtime, engine_label: Optional[str], edge_slow_mode: bool) -> bool:
    """Keep Edge alive with one local safe-mode retry before switching offline."""
    return (engine_label or "").strip().lower() == "edge" and not edge_slow_mode


def _engine_is_disabled(_runtime, engine_label: Optional[str], unavailable_engines: "set[str]") -> bool:
    """Return True when the current engine has been flagged job-wide unavailable.

    Used to short-circuit per-chapter retries after the job-wide Edge timeout
    threshold fires — otherwise every remaining chapter burns _CHAPTER_RETRY_MAX
    timeouts on the same dead engine before giving up.
    """
    return (engine_label or "").strip().lower() in unavailable_engines


def _persist_job_log(_runtime, job_id: str, job: dict) -> Optional[Path]:
    job_dir = _runtime._job_output_dir(job_id, job, ensure=True)
    if not job_dir.exists():
        return None
    log_path = job_dir / "conversion.log"
    try:
        raw_lines = job.get("_raw_log") or job.get("events") or []
        log_path.write_text("\n".join(raw_lines), encoding="utf-8")
        job["logUrl"] = f"/api/outputs/{job_id}/{log_path.name}"
        return log_path
    except Exception:
        return None
