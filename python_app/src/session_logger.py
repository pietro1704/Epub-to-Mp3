"""
Persistent conversion session logger.

Appends one JSON record per conversion to LOGS_DIR/conversions.jsonl.
The file is never auto-deleted and survives restarts.

Each record contains:
  timestamp      ISO-8601 UTC start time
  mode           "cli" | "web" | "hf"
  book_title     Title from EPUB/PDF metadata
  book_author    Author from EPUB/PDF metadata (if available)
  language       Detected/overridden language code  (e.g. "pt-BR")
  engine         Primary TTS engine used            (e.g. "edge")
  voice          Voice used                         (e.g. "pt-BR-ThalitaMultilingualNeural")
  chapters_total   Total chapters in book
  chapters_converted  Successfully converted
  chapters_failed     Failed or skipped
  duration_seconds    Wall-clock conversion time
  outcome        "success" | "partial" | "failed"
  job_id         Web/HF job UUID (absent for CLI)
  output_dir     Path to MP3 output directory
"""

from __future__ import annotations

import json
import os
import pathlib
import tempfile
import threading
from datetime import datetime, timezone
from typing import Any

from .paths import LOGS_DIR

_LOCK = threading.Lock()

# During pytest, write to a temp file so tests never pollute the real log.
if os.getenv("PYTEST_CURRENT_TEST"):
    _LOG_FILE = pathlib.Path(tempfile.gettempdir()) / "epub_to_mp3_test_sessions.jsonl"
    _EVENTS_FILE = pathlib.Path(tempfile.gettempdir()) / "epub_to_mp3_test_events.jsonl"
else:
    _LOG_FILE = LOGS_DIR / "conversions.jsonl"
    _EVENTS_FILE = LOGS_DIR / "events.jsonl"

_EVENTS_LOCK = threading.Lock()


def _detect_mode() -> str:
    """Return 'hf', 'web', or 'cli' based on environment."""
    if os.getenv("SPACE_ID"):
        return "hf"
    # SERVER_MODE is set by server.py at startup
    if os.getenv("SERVER_MODE"):
        return "web"
    return "cli"


def log_session(
    *,
    book_title: str,
    book_author: str = "",
    language: str = "",
    engine: str = "",
    voice: str = "",
    chapters_total: int = 0,
    chapters_converted: int = 0,
    chapters_failed: int = 0,
    duration_seconds: float = 0.0,
    outcome: str = "success",
    job_id: str = "",
    output_dir: str = "",
    mode: str = "",
    started_at: str = "",
    chapter_details: list[dict[str, Any]] | None = None,
    extra: dict[str, Any] | None = None,
) -> None:
    """Append a conversion session record to conversions.jsonl.

    Safe to call from multiple threads/processes — uses a threading lock
    and append mode (atomic on POSIX).
    """
    record: dict[str, Any] = {
        "timestamp": started_at or datetime.now(timezone.utc).isoformat(),
        "mode": mode or _detect_mode(),
        "book_title": book_title,
        "book_author": book_author,
        "language": language,
        "engine": engine,
        "voice": voice,
        "chapters_total": chapters_total,
        "chapters_converted": chapters_converted,
        "chapters_failed": chapters_failed,
        "duration_seconds": round(duration_seconds, 1),
        "outcome": outcome,
    }
    if job_id:
        record["job_id"] = job_id
    if output_dir:
        record["output_dir"] = output_dir
    if chapter_details:
        record["chapter_details"] = chapter_details
    if extra:
        record.update(extra)

    line = json.dumps(record, ensure_ascii=False) + "\n"
    with _LOCK:
        with open(_LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line)


def read_sessions(last_n: int = 0) -> list[dict[str, Any]]:
    """Return all (or last N) session records from conversions.jsonl."""
    if not _LOG_FILE.exists():
        return []
    records = []
    with open(_LOG_FILE, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    if last_n > 0:
        return records[-last_n:]
    return records


def log_event(kind: str, **fields: Any) -> None:
    """Append a structured event (perf/error/freeze) to events.jsonl.

    Never raises — logging must not perturb the conversion pipeline.
    """
    if not kind:
        return
    record: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "mode": _detect_mode(),
        "kind": kind,
    }
    for k, v in fields.items():
        if v is None or v == "":
            continue
        record[k] = v
    try:
        line = json.dumps(record, ensure_ascii=False, default=str) + "\n"
        with _EVENTS_LOCK:
            with open(_EVENTS_FILE, "a", encoding="utf-8") as fh:
                fh.write(line)
    except Exception:
        pass


def log_chapter_perf(
    *,
    book_title: str = "",
    chapter_index: int = 0,
    chapter_name: str = "",
    engine: str = "",
    elapsed_seconds: float = 0.0,
    char_count: int = 0,
    job_id: str = "",
    chapter_id: str = "",
) -> None:
    """Record successful per-chapter completion with throughput."""
    chars_per_sec = (
        round(char_count / elapsed_seconds, 1) if elapsed_seconds > 0 and char_count > 0 else 0.0
    )
    log_event(
        "chapter_perf",
        book_title=book_title,
        chapter_index=chapter_index,
        chapter_name=chapter_name,
        engine=engine,
        elapsed_seconds=round(float(elapsed_seconds or 0.0), 2),
        char_count=int(char_count or 0),
        chars_per_second=chars_per_sec,
        job_id=job_id,
        chapter_id=chapter_id,
    )


def log_chapter_error(
    *,
    book_title: str = "",
    chapter_index: int = 0,
    chapter_name: str = "",
    engine: str = "",
    error: str = "",
    elapsed_seconds: float = 0.0,
    job_id: str = "",
    chapter_id: str = "",
) -> None:
    """Record a per-chapter failure (engine exception, fallback exhausted, etc.)."""
    log_event(
        "chapter_error",
        book_title=book_title,
        chapter_index=chapter_index,
        chapter_name=chapter_name,
        engine=engine,
        error=str(error)[:500],
        elapsed_seconds=round(float(elapsed_seconds or 0.0), 2),
        job_id=job_id,
        chapter_id=chapter_id,
    )


def log_freeze(
    *,
    source: str,
    book_title: str = "",
    chapter_index: int = 0,
    engine: str = "",
    stalled_seconds: float = 0.0,
    threshold_seconds: float = 0.0,
    action: str = "",
    job_id: str = "",
) -> None:
    """Record a stall/freeze detection (watchdog trip).

    `source` identifies which watchdog fired:
      - 'health' (no chapter completed for N seconds)
      - 'chapter_stall' (single chapter stuck mid-synthesis)
      - 'segment_idle' (no chunk progress within N seconds)
      - 'job_stall' (server-side job stall)
    """
    log_event(
        "freeze",
        source=source,
        book_title=book_title,
        chapter_index=chapter_index,
        engine=engine,
        stalled_seconds=round(float(stalled_seconds or 0.0), 1),
        threshold_seconds=round(float(threshold_seconds or 0.0), 1),
        action=action,
        job_id=job_id,
    )


def read_events(last_n: int = 0, kind: str = "") -> list[dict[str, Any]]:
    """Return all (or last N) event records, optionally filtered by `kind`."""
    if not _EVENTS_FILE.exists():
        return []
    records: list[dict[str, Any]] = []
    with open(_EVENTS_FILE, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if kind and rec.get("kind") != kind:
                continue
            records.append(rec)
    if last_n > 0:
        return records[-last_n:]
    return records


def clear_events() -> int:
    """Delete all event records. Returns the count of deleted records."""
    if not _EVENTS_FILE.exists():
        return 0
    count = len(read_events())
    _EVENTS_FILE.unlink()
    return count


def clear_sessions() -> int:
    """Delete all session records. Returns the count of deleted records."""
    if not _LOG_FILE.exists():
        return 0
    records = read_sessions()
    count = len(records)
    _LOG_FILE.unlink()
    return count
