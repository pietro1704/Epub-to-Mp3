"""Conversion-loop helpers extracted from process_conversion in server.py.

Contains pure logic extracted from the nested functions inside
``process_conversion``.  All functions are module-level and receive their
required state via explicit parameters so they can be tested independently
and to avoid circular imports (server globals are *not* imported at module
level — the few that are needed are imported lazily inside function bodies).
"""

from __future__ import annotations

import re
import time
from pathlib import Path
from typing import TYPE_CHECKING, Optional

if TYPE_CHECKING:
    from src.engine_pool import JobEnginePool

# ---------------------------------------------------------------------------
# Progress accounting
# ---------------------------------------------------------------------------


def count_words(text: str) -> int:
    """Return a language-agnostic word count for ETA calculations."""
    if not text:
        return 0
    return len(re.findall(r"\b\w+\b", text, flags=re.UNICODE))


def _sync_entry_progress(job: dict, chapter_index: int) -> None:
    """Mirror chapter char counters into the public chapterProgress entry."""
    entries = job.get("chapterProgress")
    if not isinstance(entries, list):
        return
    target = next(
        (
            entry
            for entry in entries
            if isinstance(entry, dict) and entry.get("index") == chapter_index
        ),
        None,
    )
    if not isinstance(target, dict):
        return
    chapter_totals = job.get("_chapterCharTotals") or {}
    chapter_processed = job.get("_chapterCharProcessed") or {}
    total = int(chapter_totals.get(chapter_index, 0) or 0)
    processed = int(chapter_processed.get(chapter_index, 0) or 0)
    if total > 0:
        target["chars"] = total
    if processed > 0 or "charsProcessed" in target:
        target["charsProcessed"] = max(0, min(processed, total or processed))
    if total > 0:
        target["progressRatio"] = round(
            max(0.0, min(1.0, (target.get("charsProcessed", 0) or 0) / total)),
            4,
        )


def recalculate_progress(job: dict, chapters_count: int) -> float:
    """Recalculate and store ``progressPercent`` in *job*.

    Uses char-based accounting when ``totalChars`` is set; falls back to
    chapter-count ratio otherwise.  The progress value never decreases (it
    is clamped to be >= the current stored value).
    """
    total_for_job = job.get("totalChars") or 0
    processed_for_job = job.get("processedChars") or 0
    if total_for_job > 0:
        progress = (processed_for_job / total_for_job) * 100
    else:
        completed = max(0, min(chapters_count, job.get("chaptersCompleted", 0)))
        progress = (completed / max(chapters_count, 1)) * 100
    progress = max(job.get("progressPercent") or 0.0, min(100.0, max(0.0, progress)))
    job["progressPercent"] = progress
    return progress


def broadcast_progress(job: dict, *, force: bool = False) -> None:
    """Schedule a SSE broadcast if enough time has elapsed since the last one.

    Throttled to at most one broadcast every 0.5 s unless *force* is True.
    Uses a lazy import of ``_schedule_job_broadcast`` from server to avoid
    circular imports.
    """
    from python_app import server as _srv  # lazy — circular-import safe

    now = time.time()
    last_emit = job.get("_lastProgressBroadcast") or 0.0
    if force or (now - last_emit) >= 0.5:
        job["_lastProgressBroadcast"] = now
        _srv._schedule_job_broadcast(job.get("jobId"), job)


def update_job_progress(job: dict, chapters_count: int, *, force_broadcast: bool = False) -> None:
    """Recalculate progress and optionally force a broadcast."""
    recalculate_progress(job, chapters_count)
    if force_broadcast:
        broadcast_progress(job, force=True)


def advance_chapter_progress(
    job: dict,
    chapter_index: int,
    segment_text: str,
    chapters_count: int,
    total_text_chars: Optional[int] = None,
) -> None:
    """Credit *segment_text* chars towards the chapter's processed total.

    If *total_text_chars* is provided and larger than the stored chapter
    total the totals are updated accordingly (edge-case: chunked engines that
    report the running total on each callback).
    """
    if not segment_text:
        return
    chapter_totals = job.get("_chapterCharTotals") or {}
    chapter_processed = job.get("_chapterCharProcessed") or {}
    chapter_total = chapter_totals.get(chapter_index)
    if total_text_chars and total_text_chars > 0:
        if chapter_total is None or total_text_chars > chapter_total:
            delta_total = total_text_chars - (chapter_total or 0)
            chapter_totals[chapter_index] = total_text_chars
            job["_chapterCharTotals"] = chapter_totals
            job["totalChars"] = max(0, (job.get("totalChars") or 0) + delta_total)
            chapter_total = total_text_chars
    current_processed = int(chapter_processed.get(chapter_index, 0) or 0)
    delta = len(segment_text)
    if chapter_total and chapter_total > 0:
        remaining = max(chapter_total - current_processed, 0)
        delta = min(delta, remaining)
    if delta <= 0:
        return
    chapter_processed[chapter_index] = current_processed + delta
    job["_chapterCharProcessed"] = chapter_processed
    job["processedChars"] = min(
        job.get("totalChars") or 0, (job.get("processedChars") or 0) + delta
    )
    chapter_progress_ts = job.get("_chapterLastProgressUpdate") or {}
    chapter_progress_ts[chapter_index] = time.time()
    job["_chapterLastProgressUpdate"] = chapter_progress_ts
    _sync_entry_progress(job, chapter_index)
    update_job_progress(job, chapters_count)
    broadcast_progress(job)


def complete_chapter_progress(
    job: dict,
    chapter_index: int,
    chapters_count: int,
    *,
    broadcast: bool = True,
) -> None:
    """Mark a chapter as fully processed (fills any remaining chars gap)."""
    chapter_totals = job.get("_chapterCharTotals") or {}
    chapter_processed = job.get("_chapterCharProcessed") or {}
    chapter_total = int(chapter_totals.get(chapter_index, 0) or 0)
    if chapter_total > 0:
        current_processed = int(chapter_processed.get(chapter_index, 0) or 0)
        if chapter_total > current_processed:
            delta = chapter_total - current_processed
            chapter_processed[chapter_index] = chapter_total
            job["_chapterCharProcessed"] = chapter_processed
            job["processedChars"] = min(
                job.get("totalChars") or 0, (job.get("processedChars") or 0) + delta
            )
    chapter_progress_ts = job.get("_chapterLastProgressUpdate") or {}
    chapter_progress_ts[chapter_index] = time.time()
    job["_chapterLastProgressUpdate"] = chapter_progress_ts
    _sync_entry_progress(job, chapter_index)
    update_job_progress(job, chapters_count, force_broadcast=broadcast)


def update_estimated_chapter_progress(
    job: dict,
    chapter_index: int,
    ratio: float,
    chapters_count: int,
) -> None:
    """Push estimated progress to *ratio* (0–1) of a chapter's total chars.

    Clamped to 97 % so the final ``complete_chapter_progress`` call always
    adds a non-zero delta.  No-op if *ratio* <= 0 or the chapter has already
    advanced past the target.
    """
    if ratio <= 0:
        return
    chapter_totals = job.get("_chapterCharTotals") or {}
    chapter_processed = job.get("_chapterCharProcessed") or {}
    chapter_total = int(chapter_totals.get(chapter_index, 0) or 0)
    if chapter_total <= 0:
        return
    clamped_ratio = min(max(ratio, 0.0), 0.97)
    target = int(chapter_total * clamped_ratio)
    current_processed = int(chapter_processed.get(chapter_index, 0) or 0)
    if target <= current_processed:
        return
    delta = target - current_processed
    chapter_processed[chapter_index] = target
    job["_chapterCharProcessed"] = chapter_processed
    job["processedChars"] = min(
        job.get("totalChars") or 0, (job.get("processedChars") or 0) + delta
    )
    chapter_progress_ts = job.get("_chapterLastProgressUpdate") or {}
    chapter_progress_ts[chapter_index] = time.time()
    job["_chapterLastProgressUpdate"] = chapter_progress_ts
    _sync_entry_progress(job, chapter_index)
    update_job_progress(job, chapters_count)
    broadcast_progress(job)


# ---------------------------------------------------------------------------
# Chapter completion counting
# ---------------------------------------------------------------------------


def count_completed_chapters(job: dict) -> int:
    """Return the number of chapters with status 'completed' or 'skipped'."""
    entries = job.get("chapterProgress") or []
    return sum(
        1
        for entry in entries
        if isinstance(entry, dict) and entry.get("status") in {"completed", "skipped"}
    )


def refresh_chapter_completion(job: dict) -> None:
    """Update ``chaptersCompleted`` in *job* from chapter progress entries."""
    job["chaptersCompleted"] = count_completed_chapters(job)


# ---------------------------------------------------------------------------
# Chapter collection helpers
# ---------------------------------------------------------------------------


def chapter_requires_audio(chapter_obj: object) -> bool:
    """Return True when *chapter_obj* has non-empty audible content."""
    chapter_text = (
        getattr(chapter_obj, "speech_text", None) or getattr(chapter_obj, "text", "") or ""
    )
    return bool(chapter_text and chapter_text.strip())


def expected_output_path(
    job_output_dir: Path,
    chapter_index: int,
    chapter_obj: object,
) -> Path:
    """Return the canonical MP3 output path for *chapter_index*."""
    from src.utils import FileManager  # available without server import

    chapter_name = getattr(chapter_obj, "name", f"Chapter {chapter_index}")
    safe_name = FileManager.sanitize_filename(chapter_name)
    return job_output_dir / f"{chapter_index:03d} - {safe_name}.mp3"


def collect_failed_chapters(job: dict, chapters: list) -> list[tuple[int, object]]:
    """Return list of (index, chapter) pairs whose progress status is 'failed'."""
    entries = job.get("chapterProgress") or []
    failed: list[tuple[int, object]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if entry.get("status") != "failed":
            continue
        idx = entry.get("index")
        if not isinstance(idx, int):
            continue
        if idx < 1 or idx > len(chapters):
            continue
        failed.append((idx, chapters[idx - 1]))
    return failed


def collect_missing_chapters(
    chapters: list,
    job_output_dir: Path,
) -> list[tuple[int, object]]:
    """Return chapters that require audio but have no (or empty) output file."""
    missing: list[tuple[int, object]] = []
    for idx, chapter in enumerate(chapters, 1):
        if not chapter_requires_audio(chapter):
            continue
        output_file = expected_output_path(job_output_dir, idx, chapter)
        try:
            if not output_file.exists() or output_file.stat().st_size <= 0:
                missing.append((idx, chapter))
        except OSError:
            missing.append((idx, chapter))
    return missing


# ---------------------------------------------------------------------------
# Soft-failure tracking
# ---------------------------------------------------------------------------


def sync_soft_failures(job: dict, failed_indices: set[int]) -> None:
    """Keep ``softFailures`` list in sync with the current *failed_indices* set.

    Entries for indices no longer in *failed_indices* are removed;
    the remainder is de-duplicated (last entry wins for each index).
    """
    if not failed_indices:
        job["softFailures"] = []
        job.pop("softFailureCount", None)
        return
    soft_failures = job.get("softFailures") or []
    deduped: list[dict] = []
    seen: set[int] = set()
    for entry in reversed(soft_failures):
        if not isinstance(entry, dict):
            continue
        idx = entry.get("index")
        if not isinstance(idx, int) or idx not in failed_indices or idx in seen:
            continue
        deduped.append(entry)
        seen.add(idx)
    deduped.reverse()
    job["softFailures"] = deduped
    job["softFailureCount"] = len(deduped)


# ---------------------------------------------------------------------------
# Retry tracking
# ---------------------------------------------------------------------------


def note_chapter_attempt(chapter_attempts: dict[int, int], chapter_index: int) -> int:
    """Increment and return the attempt count for *chapter_index*."""
    attempt = chapter_attempts.get(chapter_index, 0) + 1
    chapter_attempts[chapter_index] = attempt
    return attempt


def chapter_can_retry(
    chapter_attempts: dict[int, int],
    chapter_index: int,
    *,
    retry_forever: bool,
    max_chapter_attempts: int,
    retry_forever_max: int,
) -> bool:
    """Return True when *chapter_index* has attempts remaining."""
    attempts = chapter_attempts.get(chapter_index, 0)
    if retry_forever:
        return attempts < retry_forever_max
    return attempts < max_chapter_attempts


def reset_chapter_progress_tracking(
    job: dict,
    chapter_index: int,
    chapters_count: int,
) -> None:
    """Zero out processed-char counters for *chapter_index* and broadcast."""
    chapter_processed = job.get("_chapterCharProcessed") or {}
    if chapter_index in chapter_processed:
        chapter_processed[chapter_index] = 0
        job["_chapterCharProcessed"] = chapter_processed
        job["processedChars"] = sum(int(value or 0) for value in chapter_processed.values())
    chapter_progress_ts = job.get("_chapterLastProgressUpdate") or {}
    chapter_progress_ts[chapter_index] = 0.0
    job["_chapterLastProgressUpdate"] = chapter_progress_ts
    _sync_entry_progress(job, chapter_index)
    update_job_progress(job, chapters_count, force_broadcast=True)


# ---------------------------------------------------------------------------
# TTS output path resolution
# ---------------------------------------------------------------------------


def resolve_tts_output(target_mp3: Path, engine_name: str) -> tuple[Path, bool]:
    """Return *(tts_path, needs_transcode)* for the given engine.

    Engines that emit WAV (coqui, piper) get a ``.wav`` side-car path and
    ``needs_transcode=True``; all others write directly to *target_mp3*.
    """
    if engine_name.lower() in {"coqui", "piper"}:
        return target_mp3.with_suffix(".wav"), True
    return target_mp3, False


# ---------------------------------------------------------------------------
# Edge retry parameter calculation
# ---------------------------------------------------------------------------


def edge_retry_adjustments(edge_config: object, attempt: int) -> dict[str, float]:
    """Return reduced Edge-TTS parameters to use on retry attempt *attempt*.

    Each successive attempt reduces chunk size and segment seconds by ~25 %
    and ~15 % respectively, with hard floors of 1 200 chars and 30 s.
    """
    chunk = int(getattr(edge_config, "edge_chunk_chars", 8000) or 8000)
    seg = float(getattr(edge_config, "edge_max_segment_seconds", 75) or 75)
    factor = 0.75 ** max(1, attempt)
    chunk = max(1200, int(chunk * factor))
    seg = max(30.0, min(seg, seg * (0.85 ** max(1, attempt))))
    return {
        "chunk_char_limit": chunk,
        "max_segment_seconds": seg,
        "words_per_minute": 160,
    }


# ---------------------------------------------------------------------------
# Parallel-slot computation
# ---------------------------------------------------------------------------


def compute_parallel_slots(
    *,
    force_sequential: bool,
    retrying_failed_chapters: bool,
    requested_slots: int,
    edge_cap: int,
    parallel_slots_cap: Optional[int],
    jobs: dict,
) -> int:
    """Compute the current target parallel-slot count from system constraints.

    Returns at least 1 and at most *requested_slots* (further limited by
    *edge_cap* and *parallel_slots_cap* when set).
    """
    from python_app import server as _srv  # lazy — avoids circular import

    if force_sequential or retrying_failed_chapters:
        return 1
    target_slots = _srv._determine_parallel_slots(requested_slots)
    if edge_cap > 0:
        target_slots = min(target_slots, edge_cap)
    if parallel_slots_cap:
        target_slots = min(target_slots, parallel_slots_cap)
    active_jobs = sum(1 for job_data in jobs.values() if job_data.get("state") == "running")
    if active_jobs > 1:
        target_slots = max(1, target_slots // active_jobs)
    return max(1, target_slots)


# ---------------------------------------------------------------------------
# Recent speed from chapter progress / telemetry
# ---------------------------------------------------------------------------


def resolve_recent_speed(job: dict, engine_name: str) -> float:
    """Return the most recent chars/s figure for *engine_name*.

    Checks chapter-progress entries first (most recent complete chapter),
    then falls back to the global telemetry summary.
    """
    from python_app import server as _srv  # lazy

    entries = job.get("chapterProgress") or []
    for entry in reversed(entries):
        if isinstance(entry, dict):
            value = entry.get("charsPerSecond")
            if isinstance(value, (int, float)) and value > 0:
                return float(value)
    summary = _srv.telemetry.summary()
    engine_key = (engine_name or "").lower()
    stats = summary.get(engine_key) or {}
    return float(stats.get("avg_chars_per_second") or 0.0)


# ---------------------------------------------------------------------------
# Mark retry round
# ---------------------------------------------------------------------------


def mark_retry_round(
    job: dict,
    job_id: str,
    round_number: int,
    total_failed: int,
    max_retry_rounds_label: str,
    edge_configs: list,
    engine_pool: "JobEnginePool",
) -> tuple[int, int, bool]:
    """Configure state for a retry round and return updated slot counts.

    Returns *(requested_slots, parallel_slots, retrying_failed_chapters)*.
    Callers should update their local variables from the returned tuple.
    """
    from python_app import server as _srv  # lazy

    _srv._append_event(
        job,
        f"🔁 Reprocessing {total_failed} failed chapter(s) (round {round_number}/{max_retry_rounds_label})",
    )
    job["statusHint"] = f"Reprocessing failed chapters ({total_failed})"
    requested_slots = 1
    parallel_slots = 1
    job["parallelSlots"] = parallel_slots
    engine_pool.update_parallel_slots(parallel_slots)
    for cfg in edge_configs:
        cfg.edge_enable_parallel = False
    _srv._persist_job(job_id, force=True)
    return requested_slots, parallel_slots, True
