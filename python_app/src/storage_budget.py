"""LRU size-cap + TTL eviction for .cache/ and output/ directories.

Policy (both knobs env-overridable):
  CACHE_OUTPUT_MAX_BYTES  — combined budget (default 2 GiB).
  CACHE_OUTPUT_TTL_HOURS  — entries older than this are always evicted (default 24 h).

Eviction order: TTL violators first (any age), then LRU (oldest mtime) until back
under budget.  Active jobs (passed in as ``active_book_dirs``) are never touched.

Safe to call from any context:
  - All deletes use shutil.rmtree(..., ignore_errors=True) so partial failures
    never crash the caller.
  - Empty directories and unreadable stat() calls are silently skipped.
  - The function is pure / side-effect-free aside from filesystem deletes and
    optional logging.
"""

from __future__ import annotations

import logging
import os
import shutil
import time
from pathlib import Path
from typing import Collection

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Knobs
# ---------------------------------------------------------------------------

_GiB = 1024**3

_DEFAULT_MAX_BYTES = 2 * _GiB
_DEFAULT_TTL_HOURS = 24.0

CACHE_OUTPUT_MAX_BYTES: int = int(
    os.getenv("CACHE_OUTPUT_MAX_BYTES", str(_DEFAULT_MAX_BYTES)) or _DEFAULT_MAX_BYTES
)
CACHE_OUTPUT_TTL_HOURS: float = float(
    os.getenv("CACHE_OUTPUT_TTL_HOURS", str(_DEFAULT_TTL_HOURS)) or _DEFAULT_TTL_HOURS
)

# Directories inside .cache/ that must never be evicted (models, telemetry, etc.)
_PROTECTED_NAMES = frozenset(
    {
        "telemetry",
        "piper_models",
        "models",
        "hf_models",
        "huggingface",
        "hf_cache",
        "transformers",
    }
)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _dir_size(path: Path) -> int:
    """Return total byte count of all files under *path* (best-effort, skips errors)."""
    total = 0
    try:
        for entry in path.rglob("*"):
            try:
                if entry.is_file():
                    total += entry.stat().st_size
            except OSError:
                continue
    except OSError:
        pass
    return total


def _entry_mtime(path: Path) -> float:
    """Return the most recent mtime of any file inside *path*, or path's own mtime."""
    latest = 0.0
    try:
        for entry in path.rglob("*"):
            try:
                if entry.is_file():
                    t = entry.stat().st_mtime
                    if t > latest:
                        latest = t
            except OSError:
                continue
    except OSError:
        pass
    if latest == 0.0:
        try:
            latest = path.stat().st_mtime
        except OSError:
            latest = 0.0
    return latest


def _collect_entries(directory: Path, active_dirs: frozenset[Path]) -> list[dict]:
    """Return metadata dicts for each top-level subdirectory of *directory*.

    Entries whose resolved path appears in *active_dirs*, or whose name is in
    _PROTECTED_NAMES, are excluded from eviction candidates.
    """
    entries: list[dict] = []
    if not directory.is_dir():
        return entries
    try:
        children = list(directory.iterdir())
    except OSError:
        return entries
    for child in children:
        if not child.is_dir():
            continue
        if child.name in _PROTECTED_NAMES:
            continue
        try:
            resolved = child.resolve()
        except OSError:
            resolved = child
        if resolved in active_dirs:
            continue
        size = _dir_size(child)
        mtime = _entry_mtime(child)
        entries.append({"path": child, "size": size, "mtime": mtime})
    return entries


def _safe_rmtree(path: Path) -> None:
    shutil.rmtree(path, ignore_errors=True)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def evict_storage_budget(
    cache_dir: Path,
    output_dir: Path,
    *,
    max_bytes: int = CACHE_OUTPUT_MAX_BYTES,
    ttl_hours: float = CACHE_OUTPUT_TTL_HOURS,
    active_book_dirs: Collection[Path] = (),
    _now: float | None = None,
) -> dict:
    """Enforce the combined .cache/ + output/ storage budget.

    Parameters
    ----------
    cache_dir:
        The .cache/ directory (text caches per book).
    output_dir:
        The output/ directory (final MP3s and ZIPs).
    max_bytes:
        Combined byte budget.  Eviction runs when total > max_bytes.
    ttl_hours:
        Any entry (in either dir) whose newest file mtime is older than
        this many hours is always evicted, regardless of budget.
    active_book_dirs:
        Resolved Paths of book directories currently being converted.
        These are never touched.
    _now:
        Override for current time (used in tests).

    Returns
    -------
    dict with keys:
        ``evicted`` — list of Path objects removed.
        ``freed_bytes`` — total bytes freed.
        ``total_before`` — combined size before eviction.
        ``total_after`` — combined size after eviction.
    """
    now = _now if _now is not None else time.time()
    ttl_cutoff = now - ttl_hours * 3600.0

    active_resolved: frozenset[Path] = frozenset(p.resolve() for p in active_book_dirs if p)

    cache_entries = _collect_entries(cache_dir, active_resolved)
    output_entries = _collect_entries(output_dir, active_resolved)
    all_entries = cache_entries + output_entries

    total_before = sum(e["size"] for e in all_entries)

    evicted: list[Path] = []
    freed_bytes = 0

    # --- Pass 1: TTL eviction (always, regardless of budget) ---
    remaining: list[dict] = []
    for entry in all_entries:
        if entry["mtime"] < ttl_cutoff:
            _safe_rmtree(entry["path"])
            evicted.append(entry["path"])
            freed_bytes += entry["size"]
            logger.info(
                "storage_budget: TTL evict %s (%.1f h old, %d bytes)",
                entry["path"],
                (now - entry["mtime"]) / 3600,
                entry["size"],
            )
        else:
            remaining.append(entry)

    # --- Pass 2: LRU eviction until under budget ---
    current_total = sum(e["size"] for e in remaining)
    if current_total > max_bytes:
        # Sort oldest-first (LRU = evict the longest-untouched entry first)
        remaining.sort(key=lambda e: e["mtime"])
        for entry in remaining:
            if current_total <= max_bytes:
                break
            _safe_rmtree(entry["path"])
            evicted.append(entry["path"])
            freed_bytes += entry["size"]
            current_total -= entry["size"]
            logger.info(
                "storage_budget: LRU evict %s (mtime %.0f, %d bytes freed, budget %d/%d)",
                entry["path"],
                entry["mtime"],
                entry["size"],
                current_total,
                max_bytes,
            )

    total_after = total_before - freed_bytes
    if evicted:
        logger.info(
            "storage_budget: evicted %d entr(ies), freed %d bytes (%.1f MiB). "
            "Combined size: %d → %d bytes.",
            len(evicted),
            freed_bytes,
            freed_bytes / 1024**2,
            total_before,
            total_after,
        )

    return {
        "evicted": evicted,
        "freed_bytes": freed_bytes,
        "total_before": total_before,
        "total_after": total_after,
    }
