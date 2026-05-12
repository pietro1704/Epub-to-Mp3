"""Audio processing helpers extracted from server.py.

Covers: media-type guessing, audio hashing, duplicate detection, duration
measurement, chapter status management, output pre-loading, chapter preparation,
priority ordering, text preview, and output sorting.

Server-level globals are accessed via lazy imports to avoid circular imports.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import re
import threading
from collections import OrderedDict
from pathlib import Path
from typing import Optional

from src.chapter_utils import MIN_DUPLICATE_CHARS
from src.utils import FileManager

# ---------------------------------------------------------------------------
# Media type / hashing
# ---------------------------------------------------------------------------


def _guess_media_type(filename: str) -> str:
    lowered = filename.lower()
    if lowered.endswith(".mp3"):
        return "audio/mpeg"
    if lowered.endswith(".zip"):
        return "application/zip"
    return "application/octet-stream"


def _hash_audio_file(path: Path) -> str:
    hasher = hashlib.sha1()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def _hash_text_payload(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", errors="ignore")).hexdigest()


# ---------------------------------------------------------------------------
# MP3 SHA-256 for client-side verification
#
# The iOS client (and any future official client) verifies downloaded chapter
# audio against the SHA-256 advertised by the backend.  Recomputing the digest
# on every job-status read is expensive (chapter MP3s can be 5–50 MB), so we
# memoise by (absolute path, mtime, size).  The cache is bounded (LRU) so a
# long-lived server process cannot grow it unboundedly, and it is guarded by a
# lock because both the SSE broadcaster and the conversion worker may race
# on the same path right after a chapter finishes.
# ---------------------------------------------------------------------------


_SHA256_CACHE_MAX = 256
_sha256_cache: "OrderedDict[tuple[str, int, int], str]" = OrderedDict()
_sha256_cache_lock = threading.Lock()


def compute_mp3_sha256(path: Path) -> str:
    """Return the hex SHA-256 digest of *path*, with an LRU cache.

    Cache key is ``(absolute path, mtime_ns, size)``: any of these changing
    invalidates the cached digest.  Reads in 8 KB chunks so very large MP3s
    do not blow up memory.  Caller is responsible for handling the IO/FS
    error surface — this helper lets exceptions bubble.
    """
    path = Path(path)
    stat_result = path.stat()
    key = (str(path.resolve()), stat_result.st_mtime_ns, stat_result.st_size)

    with _sha256_cache_lock:
        cached = _sha256_cache.get(key)
        if cached is not None:
            # Mark as recently used.
            _sha256_cache.move_to_end(key)
            return cached

    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8192), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()

    with _sha256_cache_lock:
        _sha256_cache[key] = digest
        _sha256_cache.move_to_end(key)
        while len(_sha256_cache) > _SHA256_CACHE_MAX:
            _sha256_cache.popitem(last=False)

    return digest


def _reset_sha256_cache() -> None:
    """Test-only hook: clear the LRU cache between cases."""
    with _sha256_cache_lock:
        _sha256_cache.clear()


# ---------------------------------------------------------------------------
# Duplicate tracker
# ---------------------------------------------------------------------------


class AudioDuplicateTracker:
    def __init__(self) -> None:
        self._hashes: dict[str, dict] = {}
        self._lock = asyncio.Lock()

    async def check_duplicate(
        self,
        audio_path: Path,
        text: str,
        chapter_index: int,
        chapter_name: str,
    ) -> Optional[dict]:
        text_len = len(text or "")
        if text_len < MIN_DUPLICATE_CHARS:
            return None
        text_hash = _hash_text_payload(text)
        audio_hash = _hash_audio_file(audio_path)
        async with self._lock:
            existing = self._hashes.get(audio_hash)
            if (
                existing
                and existing.get("text_hash") != text_hash
                and existing.get("text_len", 0) >= MIN_DUPLICATE_CHARS
            ):
                return existing
            self._hashes[audio_hash] = {
                "index": chapter_index,
                "name": chapter_name,
                "text_hash": text_hash,
                "text_len": text_len,
            }
        return None


# ---------------------------------------------------------------------------
# Audio duration
# ---------------------------------------------------------------------------


async def _get_audio_duration(file_path: Path) -> float:
    """Get audio duration using ffprobe (no pydub dependency)."""
    if not file_path.exists():
        return 0.0

    try:
        # Ensure static-ffmpeg is available
        try:
            import static_ffmpeg

            static_ffmpeg.add_paths()
        except ImportError:
            pass  # Use system ffprobe

        process = await asyncio.create_subprocess_exec(
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(file_path),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await process.communicate()

        if process.returncode == 0 and stdout:
            return float(stdout.decode().strip())
    except Exception:
        pass

    # Fallback: estimate based on file size (rough approximation)
    return file_path.stat().st_size / 1000.0  # ~1KB per second for 8kbps


def _detect_short_audio_output(
    text: str,
    audio_path: Path,
    *,
    engine_label: Optional[str] = None,
) -> Optional[str]:
    """Return warning text when audio looks far shorter than expected."""
    if not text:
        return None

    engine = (engine_label or "").lower()
    if engine != "edge":
        return None

    audio_path = Path(audio_path)
    if not audio_path.exists():
        return None

    stripped = text.strip()
    if not stripped:
        return None

    # Mirror the CLI truncation check so both conversion paths use the same
    # short-chapter cutoff and EXPECTED_WPM-based completeness heuristic.
    from src.converter import validate_audio_completeness

    is_complete, coverage_percent = validate_audio_completeness(audio_path, len(stripped))
    if is_complete:
        return None

    return "Audio possibly truncated " f"({coverage_percent:.0f}% coverage, expected full chapter)"


# ---------------------------------------------------------------------------
# Chapter / job status updates
# ---------------------------------------------------------------------------


def _set_chapter_status(
    job: dict,
    chapter_index: Optional[int],
    status: str,
    download_url: Optional[str] = None,
    engine_label: Optional[str] = None,
    *,
    retry_count: Optional[int] = None,
    max_retries: Optional[int] = None,
    retry_reason: Optional[str] = None,
    param_adjustment: Optional[str] = None,
    error_message: Optional[str] = None,
) -> None:
    from python_app import server as _srv  # lazy to avoid circular import

    entries = job.get("chapterProgress")
    if not entries or chapter_index is None:
        return
    if isinstance(entries, list):
        idx = max(0, int(chapter_index) - 1)
        if idx < len(entries):
            entry = entries[idx]
            if isinstance(entry, dict):
                entry["status"] = status
                if download_url:
                    entry["downloadUrl"] = download_url
                if engine_label:
                    entry["engine"] = str(engine_label).lower()
                # Retry information
                if retry_count is not None:
                    entry["retryCount"] = retry_count
                if max_retries is not None:
                    entry["maxRetries"] = max_retries
                if retry_reason is not None:
                    entry["retryReason"] = retry_reason
                if param_adjustment is not None:
                    entry["paramAdjustment"] = param_adjustment
                # Clear retry info when completed
                if status == "completed":
                    entry.pop("retryReason", None)
                    entry.pop("paramAdjustment", None)
                # Per-chapter timing timestamps
                if status == "processing" and "startedAt" not in entry:
                    entry["startedAt"] = _srv._utcnow_iso()
                    entry["engineSequence"] = [str(engine_label).lower()] if engine_label else []
                elif status == "retrying" and engine_label:
                    seq = entry.setdefault("engineSequence", [])
                    eng = str(engine_label).lower()
                    if not seq or seq[-1] != eng:
                        seq.append(eng)
                elif status in ("completed", "failed", "skipped"):
                    entry["completedAt"] = _srv._utcnow_iso()
                # Structured error classification
                if status == "failed":
                    from src.error_classifier import classify_error

                    err_text = error_message or retry_reason or ""
                    if error_message:
                        entry["errorMessage"] = error_message
                    entry["errorCategory"] = classify_error(err_text)
    if isinstance(entries, list):
        processing = sum(
            1
            for entry in entries
            if isinstance(entry, dict) and entry.get("status") in ("processing", "retrying")
        )
        job["parallelActive"] = processing

    # Emit a lean per-chapter SSE event so the frontend can update just that card
    job_id = job.get("jobId")
    if job_id and isinstance(entries, list) and chapter_index is not None:
        idx = max(0, int(chapter_index) - 1)
        if idx < len(entries) and isinstance(entries[idx], dict):
            _srv._schedule_chapter_broadcast(job_id, dict(entries[idx]))


def _set_job_error(job: dict, message: str) -> None:
    """Set job error string and auto-classify it into a stable category."""
    from src.error_classifier import classify_error

    job["error"] = message
    job["errorCategory"] = classify_error(message)


def _set_engine_status(
    job: dict,
    engine: str,
    status: str,
    message: Optional[str] = None,
    progress: Optional[float] = None,
) -> None:
    """Update engine loading/initialization status in job."""
    from python_app import server as _srv  # lazy to avoid circular import

    job["engineStatus"] = {
        "engine": engine,
        "status": status,
        "message": message,
        "progress": progress,
    }
    _srv._schedule_job_broadcast(job.get("jobId"), job)


# ---------------------------------------------------------------------------
# Output preloading
# ---------------------------------------------------------------------------


async def _preload_existing_outputs(
    job: dict, chapters: list, job_output_dir: Path
) -> tuple[list[dict], set[int]]:
    """Detect chapters that already have audio on disk (resume support).

    First checks the progress checkpoint written during a previous run for a
    fast path: only those chapter indices are verified on disk.  Falls back to
    scanning all chapter files when no checkpoint exists.
    """
    from python_app import server as _srv  # lazy to avoid circular import

    existing_outputs: list[dict] = []
    completed_indices: set[int] = set()
    job_id = job.get("jobId")

    # Fast path: use checkpoint to know which indices to verify
    checkpoint_indices: set[int] = set()
    checkpoint_path = job_output_dir / _srv._PROGRESS_CHECKPOINT_NAME
    if checkpoint_path.exists():
        try:
            ckpt = json.loads(checkpoint_path.read_text(encoding="utf-8"))
            checkpoint_indices = {int(i) for i in (ckpt.get("completed_indices") or [])}
        except Exception:
            checkpoint_indices = set()

    # Determine which chapter indices to probe
    all_indices = range(1, len(chapters) + 1)
    probe_indices = checkpoint_indices if checkpoint_indices else set(all_indices)

    for idx, chapter in enumerate(chapters, 1):
        if idx not in probe_indices:
            continue
        chapter_name = getattr(chapter, "name", f"Chapter {idx}")
        safe_name = FileManager.sanitize_filename(chapter_name)
        output_file = job_output_dir / f"{idx:03d} - {safe_name}.mp3"
        if not output_file.exists() or output_file.stat().st_size <= 0:
            continue
        duration = await _get_audio_duration(output_file)
        download_url = f"/api/outputs/{job_id}/{output_file.name}" if job_id else output_file.name
        entry = {
            "name": output_file.name,
            "url": download_url,
            "durationSeconds": round(duration, 2),
            "sizeBytes": output_file.stat().st_size,
        }
        try:
            entry["sha256"] = compute_mp3_sha256(output_file)
        except Exception:
            pass
        existing_outputs.append(entry)
        completed_indices.add(idx)
        _set_chapter_status(
            job,
            idx,
            "completed",
            download_url=download_url,
            engine_label=job.get("engine"),
        )

    # If we used checkpoint but some indices are missing on disk, fall back to
    # a full scan so we don't miss chapters that exist but weren't checkpointed.
    if checkpoint_indices and len(existing_outputs) < len(checkpoint_indices):
        for idx, chapter in enumerate(chapters, 1):
            if idx in completed_indices or idx in probe_indices:
                continue
            chapter_name = getattr(chapter, "name", f"Chapter {idx}")
            safe_name = FileManager.sanitize_filename(chapter_name)
            output_file = job_output_dir / f"{idx:03d} - {safe_name}.mp3"
            if not output_file.exists() or output_file.stat().st_size <= 0:
                continue
            duration = await _get_audio_duration(output_file)
            download_url = (
                f"/api/outputs/{job_id}/{output_file.name}" if job_id else output_file.name
            )
            entry = {
                "name": output_file.name,
                "url": download_url,
                "durationSeconds": round(duration, 2),
                "sizeBytes": output_file.stat().st_size,
            }
            existing_outputs.append(entry)
            completed_indices.add(idx)
            _set_chapter_status(
                job,
                idx,
                "completed",
                download_url=download_url,
                engine_label=job.get("engine"),
            )

    return existing_outputs, completed_indices


# ---------------------------------------------------------------------------
# Chapter preparation
# ---------------------------------------------------------------------------


def _prepare_chapters(
    reader,
    config,
    selectors: Optional[str] = None,
    *,
    range_start: Optional[str] = None,
    range_span: Optional[str] = None,
) -> list:
    """Mirror CLI chapter processing so output matches show-structure."""
    from main import ConverterApplication

    converter_app = ConverterApplication()
    converter_app._interactive_mode = False

    try:
        structure_items = converter_app._generate_structure_items(reader)
    except Exception:
        return reader.get_chapters()

    if not structure_items:
        return reader.get_chapters()

    if range_start or range_span:
        try:
            if range_start and range_span:
                range_span = None
            if range_span:
                parsed = converter_app._parse_range_selector(range_span)
                if parsed:
                    range_start, range_end = parsed
                else:
                    range_start, range_end = None, None
            else:
                range_end = None
            if range_start:
                filtered_items, filtered = converter_app._filter_structure_range(
                    structure_items, range_start, range_end
                )
                if filtered and filtered_items:
                    structure_items = filtered_items
        except Exception:
            pass

    if selectors:
        raw_selectors = [
            token.strip() for token in re.split(r"[\s,;]+", selectors) if token.strip()
        ]
        if raw_selectors:
            try:
                filtered_items, filtered = converter_app._filter_structure_selection(
                    structure_items, raw_selectors
                )
                if filtered and filtered_items:
                    structure_items = filtered_items
            except Exception:
                pass

    try:
        # Skip slow language detection in server mode for better performance
        # Language is already set via config.primary_language
        converter_app.language_profile = None

        transformed_items = converter_app._apply_text_transforms(structure_items, config, reader)
        converter_app._apply_structure_to_reader(reader, transformed_items)
        chapters = reader.get_chapter_structure(preserve_all=config.preserve_all_chapters)
        prioritized = chapters or reader.get_chapters()
        if getattr(config, "priority_selectors", None):
            prioritized = _apply_priority_order(prioritized, config.priority_selectors)
        return prioritized
    except Exception:
        fallback = reader.get_chapters()
        if getattr(config, "priority_selectors", None):
            fallback = _apply_priority_order(fallback, config.priority_selectors)
        return fallback


def _apply_priority_order(chapters: list, selectors: list[str]) -> list:
    if not selectors:
        return chapters
    prioritized: list = []
    seen: set[int] = set()
    selectors_norm = [str(sel).strip().lower() for sel in selectors if str(sel).strip()]
    for selector in selectors_norm:
        numeric_target: Optional[int] = None
        if selector.replace(".", "", 1).isdigit():
            try:
                numeric_target = int(float(selector))
            except ValueError:
                numeric_target = None
        for idx, chapter in enumerate(chapters):
            if idx in seen:
                continue
            name = (getattr(chapter, "name", None) or f"Chapter {idx + 1}").lower()
            if numeric_target is not None and (idx + 1) == numeric_target:
                prioritized.append(chapter)
                seen.add(idx)
                break
            if selector in name:
                prioritized.append(chapter)
                seen.add(idx)
                break
    if not prioritized:
        return chapters
    remaining = [chapter for idx, chapter in enumerate(chapters) if idx not in seen]
    return prioritized + remaining


def _build_text_preview(text: str, limit: int = 180) -> str:
    if not text:
        return ""
    preview = " ".join(text.split())
    if len(preview) > limit:
        preview = preview[:limit].rstrip() + "…"
    return preview


# ---------------------------------------------------------------------------
# Output sorting
# ---------------------------------------------------------------------------


def _output_sort_key(entry: dict) -> tuple[int, str]:
    name = (entry.get("name") or "").lower()
    match = re.match(r"(\d+)", name)
    if match:
        return (int(match.group(1)), name)
    return (10**9, name)


def _sort_output_entries(entries: list[dict]) -> list[dict]:
    mp3_entries: list[dict] = []
    other_entries: list[dict] = []
    for entry in entries:
        name = (entry.get("name") or "").lower()
        if name.endswith(".mp3"):
            mp3_entries.append(entry)
        else:
            other_entries.append(entry)
    mp3_entries.sort(key=_output_sort_key)
    return other_entries + mp3_entries
