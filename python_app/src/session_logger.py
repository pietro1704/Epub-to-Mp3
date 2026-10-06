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
import sys
import tempfile
import threading
from datetime import datetime, timezone
from typing import Any

from .paths import LOGS_DIR

_LOCK = threading.Lock()


def _is_test_process() -> bool:
    """Best-effort pytest detection for log isolation.

    `PYTEST_CURRENT_TEST` is only guaranteed while an individual test is
    executing. Some imports happen earlier during collection, and those
    paths were still writing into the real `.logs/` tree. Treat the wider
    pytest process as test mode too.
    """
    return bool(
        os.getenv("PYTEST_CURRENT_TEST") or os.getenv("PYTEST_VERSION") or "pytest" in sys.modules
    )


_PROD_LOG_FILE = LOGS_DIR / "conversions.jsonl"
_PROD_EVENTS_FILE = LOGS_DIR / "events.jsonl"
_TEST_LOG_FILE = pathlib.Path(tempfile.gettempdir()) / "epub_to_mp3_test_sessions.jsonl"
_TEST_EVENTS_FILE = pathlib.Path(tempfile.gettempdir()) / "epub_to_mp3_test_events.jsonl"

# During pytest, write to a temp file so tests never pollute the real log.
if _is_test_process():
    _LOG_FILE = _TEST_LOG_FILE
    _EVENTS_FILE = _TEST_EVENTS_FILE
else:
    _LOG_FILE = _PROD_LOG_FILE
    _EVENTS_FILE = _PROD_EVENTS_FILE

_EVENTS_LOCK = threading.Lock()


def _effective_log_file() -> pathlib.Path:
    """Resolve the session-log target, re-checking test-mode at call time.

    `_LOG_FILE` is bound once at import for the common case, and existing
    tests rely on monkeypatching it directly (see test_session_logger.py).
    But if this module is first imported during pytest *collection* —
    before `PYTEST_CURRENT_TEST` exists — `_is_test_process()` can still
    return False at that instant and freeze `_LOG_FILE` on the production
    path for the rest of the process (see commit 6dfdc811 / ef696eda,
    which this call-time check was added to fully close). Redirect to the
    test file ONLY when `_LOG_FILE` still equals the untouched production
    default — an explicit monkeypatch always wins.
    """
    if _LOG_FILE == _PROD_LOG_FILE and _is_test_process():
        return _TEST_LOG_FILE
    return _LOG_FILE


def _effective_events_file() -> pathlib.Path:
    """Events-file counterpart of `_effective_log_file()`."""
    if _EVENTS_FILE == _PROD_EVENTS_FILE and _is_test_process():
        return _TEST_EVENTS_FILE
    return _EVENTS_FILE


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
        with open(_effective_log_file(), "a", encoding="utf-8") as fh:
            fh.write(line)


def read_sessions(last_n: int = 0) -> list[dict[str, Any]]:
    """Return all (or last N) session records from conversions.jsonl."""
    log_file = _effective_log_file()
    if not log_file.exists():
        return []
    records = []
    with open(log_file, encoding="utf-8") as fh:
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
            with open(_effective_events_file(), "a", encoding="utf-8") as fh:
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
    events_file = _effective_events_file()
    if not events_file.exists():
        return []
    records: list[dict[str, Any]] = []
    with open(events_file, encoding="utf-8") as fh:
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
    events_file = _effective_events_file()
    if not events_file.exists():
        return 0
    count = len(read_events())
    events_file.unlink()
    return count


def clear_sessions() -> int:
    """Delete all session records. Returns the count of deleted records."""
    log_file = _effective_log_file()
    if not log_file.exists():
        return 0
    records = read_sessions()
    count = len(records)
    log_file.unlink()
    return count
