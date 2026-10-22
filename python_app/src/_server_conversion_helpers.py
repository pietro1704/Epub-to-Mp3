"""Conversion-loop helpers extracted from process_conversion in server.py.

Contains pure logic extracted from the nested functions inside
``process_conversion``.  All functions are module-level and receive their
required state via explicit parameters so they can be tested independently
and to avoid circular imports (server globals are *not* imported at module
level — the few that are needed are imported lazily inside function bodies).
"""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING, List, Optional

from .server_job_progress import _attach_chapter_sha256 as _attach_chapter_sha256
from .server_job_progress import _sync_entry_progress as _sync_entry_progress
from .server_job_progress import advance_chapter_progress as advance_chapter_progress
from .server_job_progress import broadcast_progress as broadcast_progress
from .server_job_progress import complete_chapter_progress as complete_chapter_progress
from .server_job_progress import count_completed_chapters as count_completed_chapters
from .server_job_progress import count_words as count_words
from .server_job_progress import recalculate_progress as recalculate_progress
from .server_job_progress import refresh_chapter_completion as refresh_chapter_completion
from .server_job_progress import reset_chapter_progress_tracking as reset_chapter_progress_tracking
from .server_job_progress import (
    update_estimated_chapter_progress as update_estimated_chapter_progress,
)
from .server_job_progress import update_job_progress as update_job_progress


def preflight_language_check(
    chapters: List[object],
    config: object,
    *,
    user_language_override: bool,
) -> Optional[str]:
    """Web-job mirror of `_preflight_language_and_config_check` in main.py.

    Runs a second-pass language detection over a different chapter window
    than the first pass and returns an error string when the two
    disagree (and the user did not force `--language`). Returns None
    when everything looks consistent.

    Why mirror this on the server side: the CLI guard caught the Carl
    regression (pt-BR audiobook narrated by an English Piper model)
    before TTS started; web jobs lacked the same protection so a
    misconfigured upload would happily synthesise hours of wrong-
    language audio.
    """
    primary = (getattr(config, "primary_language", "") or "").lower()
    primary_root = primary.split("-", 1)[0]
    if not primary_root or not chapters:
        return None

    sample_texts: List[str] = []
    total_chars = 0
    mid_start = max(0, len(chapters) // 4)
    mid_end = min(len(chapters), max(mid_start + 5, (3 * len(chapters)) // 4))
    for chapter in chapters[mid_start:mid_end]:
        text = getattr(chapter, "speech_text", None) or getattr(chapter, "text", "") or ""
        if text and len(text.strip()) > 200:
            sample_texts.append(text)
            total_chars += len(text)
            if total_chars >= 5000:
                break
    if not sample_texts:
        return None

    try:
        from src.language.detector import get_language_detector

        detector = get_language_detector()
        profile = detector.detect_profile(sample_texts)
    except Exception:
        return None

    verified = (getattr(profile, "primary", None) or "").lower()
    if not verified:
        return None
    verified_root = verified.split("-", 1)[0]

    if verified_root and verified_root != primary_root:
        if user_language_override:
            return None  # user pinned the language; warn upstream but proceed.
        return (
            f"Language mismatch: first-pass detection said '{primary}', "
            f"second-pass (independent sample) said '{verified}'. "
            "Refuse to synthesise — pass language explicitly to override."
        )
    return None


def detect_reusable_existing_output(
    output_dir: Path, expected_chapters: int, *, force: bool = False
) -> Optional[Path]:
    """Server mirror of CLI's `_detect_reusable_existing_output`.

    Returns the dir if ≥90 % of the expected MP3s are already present
    and non-empty, otherwise None. ``force=True`` (operator wants a
    fresh run) always returns None.
    """
    if force or expected_chapters <= 0 or not output_dir.exists() or not output_dir.is_dir():
        return None
    mp3_count = sum(
        1 for path in output_dir.glob("*.mp3") if path.is_file() and path.stat().st_size > 0
    )
    if mp3_count == 0 or mp3_count < int(expected_chapters * 0.9):
        return None
    return output_dir


if TYPE_CHECKING:
    from src.engine_pool import JobEnginePool

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


# ---------------------------------------------------------------------------
# TTS output path resolution
# ---------------------------------------------------------------------------


def resolve_tts_output(target_mp3: Path, engine_name: str) -> tuple[Path, bool]:
    """Return *(tts_path, needs_transcode)* for the given engine.

    Engines that emit WAV (piper) get a ``.wav`` side-car path and
    ``needs_transcode=True``; all others write directly to *target_mp3*.
    """
    if engine_name.lower() in {"piper"}:
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
    then falls back to the global telemetry summary (language-aware when
    the job carries a primary language).
    """
    from python_app import server as _srv  # lazy

    entries = job.get("chapterProgress") or []
    for entry in reversed(entries):
        if isinstance(entry, dict):
            value = entry.get("charsPerSecond")
            if isinstance(value, (int, float)) and value > 0:
                return float(value)
    avg_speed_for = getattr(_srv.telemetry, "avg_speed_for", None)
    if callable(avg_speed_for):
        return float(avg_speed_for(engine_name, job.get("primaryLanguage")) or 0.0)
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
