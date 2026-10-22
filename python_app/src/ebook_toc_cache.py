# -*- coding: utf-8 -*-
"""Bounded in-memory and persistent EPUB TOC caching."""

from __future__ import annotations

from pathlib import Path
from typing import List, Optional

from .ebook_models import TocItem


def _toc_disk_cache_path(file_path: str) -> Optional[Path]:
    """Compute the on-disk TOC cache path for a given EPUB. Returns
    ``None`` when paths cannot be resolved.
    """
    from . import ebook_reader as _runtime
    try:
        from .paths import CACHE_DIR  # type: ignore

        # blake2b digest_size=8 → 16 hex chars, matching the previous
        # sha1[:16] surface so existing disk filenames are still readable
        # in length terms. The hash itself is different, so v0.3.24/v0.3.25
        # entries become orphans on first run after this change — they
        # are cleared by ``_toc_disk_cache_cleanup`` once they age past 30d.
        if _runtime.hashlib is None:
            return None
        digest = _runtime.hashlib.blake2b(
            str(file_path).encode("utf-8", errors="ignore"), digest_size=8
        ).hexdigest()
        return _runtime.Path(CACHE_DIR) / "_toc" / f"{digest}.json"
    except Exception:
        return None

def _toc_disk_cache_cleanup(max_age_days: int = 30) -> int:
    """Drop ``.cache/_toc/`` entries older than ``max_age_days``.

    Run lazily — every EPUB ever opened leaves a sha1 entry behind, and
    over months that grows unboundedly. Returns the number of entries
    removed (0 when the dir is missing). Idempotent within a process: the
    sweep runs once per process, gated by ``_TOC_DISK_CACHE_CLEANED``.
    """
    from . import ebook_reader as _runtime
    if _runtime._TOC_DISK_CACHE_CLEANED:
        return 0
    _runtime._TOC_DISK_CACHE_CLEANED = True
    try:
        from .paths import CACHE_DIR  # type: ignore

        toc_dir = _runtime.Path(CACHE_DIR) / "_toc"
    except Exception:
        return 0
    if not toc_dir.exists() or not toc_dir.is_dir():
        return 0
    cutoff = _runtime.time.time() - max(1, max_age_days) * 86400
    removed = 0
    try:
        entries = list(toc_dir.iterdir())
    except OSError:
        return 0
    for entry in entries:
        if not entry.is_file():
            continue
        try:
            if entry.stat().st_mtime < cutoff:
                entry.unlink()
                removed += 1
        except OSError:
            continue
    return removed

def _toc_to_jsonable(items: List["TocItem"]) -> list:
    """Serialize TocItem tree to plain dicts."""
    from . import ebook_reader as _runtime
    out = []
    for it in items:
        out.append(
            {
                "title": it.title,
                "href": it.href,
                "level": it.level,
                "children": _runtime._toc_to_jsonable(it.children) if it.children else [],
            }
        )
    return out

def _toc_from_jsonable(data: list) -> List["TocItem"]:
    from . import ebook_reader as _runtime
    out: List[_runtime.TocItem] = []
    for entry in data or []:
        children = _runtime._toc_from_jsonable(entry.get("children") or [])
        out.append(
            _runtime.TocItem(
                title=entry.get("title", "") or "",
                href=entry.get("href", "") or "",
                level=int(entry.get("level") or 1),
                children=children,
            )
        )
    return out

def _toc_cache_get(file_path: str, opf_path: Optional[str]) -> Optional[List[TocItem]]:
    from . import ebook_reader as _runtime
    try:
        mtime_ns = _runtime.os.stat(file_path).st_mtime_ns
    except OSError:
        return None
    key = (file_path, mtime_ns, opf_path or "")
    hit = _runtime._toc_cache.get(key)
    if hit is not None:
        _runtime._toc_cache.move_to_end(key)
        return list(hit)
    # Persistent cache: same EPUB across CLI runs reuses the parsed TOC
    # without paying the XML walk again. Keyed on mtime_ns + opf_path so
    # an edition swap (different EPUB at the same path) invalidates.
    disk_path = _runtime._toc_disk_cache_path(file_path)
    if disk_path is not None and disk_path.exists():
        try:
            payload = _runtime.json.loads(disk_path.read_text(encoding="utf-8"))
            if (
                isinstance(payload, dict)
                and int(payload.get("mtime_ns") or 0) == mtime_ns
                and (payload.get("opf_path") or "") == (opf_path or "")
            ):
                items = _runtime._toc_from_jsonable(payload.get("toc") or [])
                # Promote into the in-memory LRU.
                _runtime._toc_cache[key] = list(items)
                while len(_runtime._toc_cache) > _runtime._TOC_CACHE_MAX:
                    _runtime._toc_cache.popitem(last=False)
                return list(items)
        except Exception:
            pass
    return None

def _toc_cache_put(file_path: str, opf_path: Optional[str], items: List[TocItem]) -> None:
    from . import ebook_reader as _runtime
    try:
        mtime_ns = _runtime.os.stat(file_path).st_mtime_ns
    except OSError:
        return
    key = (file_path, mtime_ns, opf_path or "")
    _runtime._toc_cache[key] = list(items)
    while len(_runtime._toc_cache) > _runtime._TOC_CACHE_MAX:
        _runtime._toc_cache.popitem(last=False)
    # Lazy GC of stale persistent entries — runs once per process the
    # first time a TOC is written. Keeps the disk cache bounded across
    # months of use without any explicit maintenance step.
    try:
        _runtime._toc_disk_cache_cleanup()
    except Exception:
        pass
    # Best-effort persistent cache write.
    disk_path = _runtime._toc_disk_cache_path(file_path)
    if disk_path is not None:
        try:
            disk_path.parent.mkdir(parents=True, exist_ok=True)
            disk_path.write_text(
                _runtime.json.dumps(
                    {
                        "mtime_ns": mtime_ns,
                        "opf_path": opf_path or "",
                        "toc": _runtime._toc_to_jsonable(items),
                    }
                ),
                encoding="utf-8",
            )
        except Exception:
            pass
