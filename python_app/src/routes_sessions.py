"""Session history route handlers.

Extracted from server.py to reduce its line count.  No server-level globals
are needed here — session data is accessed through the session_logger module.
"""

from __future__ import annotations

from fastapi import APIRouter

router = APIRouter(prefix="/api", tags=["sessions"])


@router.get("/sessions")
async def get_sessions(last: int = 0) -> dict:
    """Return conversion session history from the persistent log.

    Query params:
        last (int): Return only the last N sessions (0 = all, default).

    Returns a list of session records, newest last, plus aggregate stats.
    """
    from src.session_logger import read_sessions

    safe_last = max(0, min(1000, int(last or 0)))
    records = read_sessions(last_n=safe_last)

    # Aggregate stats across returned records
    total = len(records)
    outcomes: dict[str, int] = {}
    engines: dict[str, int] = {}
    modes: dict[str, int] = {}
    total_duration = 0.0
    total_chapters = 0

    for r in records:
        outcomes[r.get("outcome", "unknown")] = outcomes.get(r.get("outcome", "unknown"), 0) + 1
        eng = r.get("engine", "")
        if eng:
            engines[eng] = engines.get(eng, 0) + 1
        mode = r.get("mode", "")
        if mode:
            modes[mode] = modes.get(mode, 0) + 1
        total_duration += r.get("duration_seconds", 0.0) or 0.0
        total_chapters += r.get("chapters_converted", 0) or 0

    return {
        "sessions": records,
        "count": total,
        "stats": {
            "outcomes": outcomes,
            "engines": engines,
            "modes": modes,
            "total_duration_seconds": round(total_duration, 1),
            "total_chapters_converted": total_chapters,
        },
    }


@router.delete("/sessions")
async def delete_sessions() -> dict:
    """Delete all session history records."""
    from src.session_logger import clear_sessions

    deleted = clear_sessions()
    return {"deleted": deleted}
