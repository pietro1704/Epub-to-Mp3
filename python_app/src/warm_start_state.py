"""Persist and age engine/voice/language warm-start evidence."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict


def warmup_output_path(base_dir: Path, engine: str) -> Path:
    ext = ".mp3" if (engine or "").lower() == "edge" else ".wav"
    return base_dir / f"{(engine or 'engine').lower()}-warmup{ext}"


def load_warm_start_state(path, ttl_seconds, *, enabled, clock, save_entries) -> Dict[str, Any]:
    if not enabled or not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        entries = payload.get("entries", {}) if isinstance(payload, dict) else {}
        if not isinstance(entries, dict):
            return {}
        now = clock()
        ttl = max(60.0, float(payload.get("ttl_seconds", ttl_seconds) or 0.0))
        cleaned: Dict[str, Any] = {}
        changed = False
        for key, raw in entries.items():
            if not isinstance(raw, dict):
                changed = True
                continue
            ts = float(raw.get("ts", 0.0) or 0.0)
            if ts <= 0 or (now - ts) > ttl:
                changed = True
                continue
            cleaned[str(key)] = {"ts": ts}
        if changed:
            save_entries(cleaned)
        return cleaned
    except Exception:
        return {}


def save_warm_start_state(path, ttl_seconds, entries, *, enabled, clock) -> None:
    if not enabled:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "updated_at": clock(),
            "ttl_seconds": ttl_seconds,
            "entries": entries,
        }
        path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    except Exception:
        return


def warm_start_is_fresh(entries, key, ttl_seconds, *, clock) -> bool:
    raw = entries.get(key)
    if not isinstance(raw, dict):
        return False
    ts = float(raw.get("ts", 0.0) or 0.0)
    if ts <= 0:
        return False
    return (clock() - ts) <= ttl_seconds


def mark_warm_start_ready(entries, key, *, clock, save_entries) -> None:
    entries[key] = {"ts": clock()}
    if len(entries) > 300:
        sorted_keys = sorted(
            entries.keys(),
            key=lambda item: float((entries.get(item) or {}).get("ts", 0.0) or 0.0),
            reverse=True,
        )
        entries = {name: entries[name] for name in sorted_keys[:200]}
    save_entries(entries)
