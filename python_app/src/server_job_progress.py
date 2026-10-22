"""Job/chapter progress accounting, SSE emission and completed-artifact digests."""

from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Optional

# Progress accounting


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
    output_path: Optional[Path] = None,
) -> None:
    """Mark a chapter as fully processed (fills any remaining chars gap).

    When *output_path* is provided and the file exists, the chapter's
    SHA-256 digest is computed and stored in the matching ``chapterProgress``
    entry under the ``sha256`` key so the client can verify the download.
    SHA computation is best-effort: any error (missing file, IO, hashing)
    is logged at warning level and the field is omitted — it must never
    block the conversion pipeline.
    """
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
    if output_path is not None:
        _attach_chapter_sha256(job, chapter_index, output_path)
    update_job_progress(job, chapters_count, force_broadcast=broadcast)



def _attach_chapter_sha256(job: dict, chapter_index: int, output_path: Path) -> None:
    """Compute the SHA-256 of *output_path* and store it on the chapter entry.

    Failures are logged as warnings and swallowed: SHA is an optional field
    for client-side verification and must not abort the job.
    """
    import logging

    from src._server_audio_helpers import compute_mp3_sha256

    logger = logging.getLogger(__name__)
    output_path = Path(output_path)
    try:
        if not output_path.exists() or output_path.stat().st_size <= 0:
            return
        digest = compute_mp3_sha256(output_path)
    except Exception as exc:  # pragma: no cover - defensive
        logger.warning(
            "Failed to compute SHA-256 for chapter %s (%s): %s",
            chapter_index,
            output_path,
            exc,
        )
        return

    entries = job.get("chapterProgress")
    if not isinstance(entries, list):
        return
    target = None
    for entry in entries:
        if isinstance(entry, dict) and entry.get("index") == chapter_index:
            target = entry
            break
    if target is None:
        # Fall back to 1-based positional lookup used elsewhere in the server.
        idx = max(0, int(chapter_index) - 1)
        if 0 <= idx < len(entries) and isinstance(entries[idx], dict):
            target = entries[idx]
    if target is not None:
        target["sha256"] = digest



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



# Chapter completion counting


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
