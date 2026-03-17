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
import threading
from datetime import datetime, timezone
from typing import Any

from .paths import LOGS_DIR

_LOCK = threading.Lock()
_LOG_FILE = LOGS_DIR / "conversions.jsonl"


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
