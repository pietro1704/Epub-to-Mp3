# -*- coding: utf-8 -*-
"""Lazy persistent cache, cover metadata and restart markers."""

from __future__ import annotations

from typing import Dict, Optional


from .cache_manager import CacheManager


def get_cache_manager(_runtime, ) -> CacheManager:
    """Return the CacheManager singleton using the persistent directory."""
    if _runtime._persistent_cache_manager is None:
        _runtime._persistent_cache_manager = _runtime.CacheManager(cache_dir=_runtime.persistent_cache_dir)
    return _runtime._persistent_cache_manager


def _load_cover_cache(_runtime, ) -> Dict[str, dict]:
    try:
        return _runtime.json.loads(_runtime.cover_index_path.read_text())
    except Exception:
        return {}


def _save_cover_cache(_runtime, index: Dict[str, dict]) -> None:
    try:
        _runtime._atomic_write_text(_runtime.cover_index_path, _runtime.json.dumps(index))
    except Exception:
        pass


def _load_restart_marker(_runtime, ) -> Optional[dict]:
    try:
        data = _runtime.json.loads(_runtime._restart_marker_path.read_text())
    except FileNotFoundError:
        return None
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def _write_restart_marker(_runtime, *, keep_cache: bool, keep_finished: bool) -> None:
    payload = {
        "keep_cache": bool(keep_cache),
        "keep_finished": bool(keep_finished),
        "created_at": _runtime.time.time(),
    }
    try:
        _runtime._restart_marker_path.write_text(_runtime.json.dumps(payload))
    except Exception:
        pass


def _clear_restart_marker(_runtime, ) -> None:
    with _runtime.contextlib.suppress(OSError):
        _runtime._restart_marker_path.unlink(missing_ok=True)
