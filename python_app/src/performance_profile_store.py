# -*- coding: utf-8 -*-
"""Persistent store for best-performing runtime params per engine/voice/language."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Dict, Optional

from .paths import TELEMETRY_DIR


class PerformanceProfileStore:
    """Read/write lightweight performance profiles in telemetry cache."""

    def __init__(self, path: Optional[Path] = None) -> None:
        self.path = Path(path or (TELEMETRY_DIR / "performance-profiles.json"))

    @staticmethod
    def _key(engine: str, voice: str, language: str, machine_signature: str = "") -> str:
        return (
            f"{(engine or '').strip().lower()}"
            f"|{(voice or '').strip().lower()}"
            f"|{(language or '').strip().lower()}"
            f"|{(machine_signature or '').strip().lower()}"
        )

    def _load(self) -> Dict[str, object]:
        if not self.path.exists():
            return {"version": 1, "profiles": {}}
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(payload, dict) and isinstance(payload.get("profiles"), dict):
                return payload
        except Exception:
            pass
        return {"version": 1, "profiles": {}}

    def _save(self, payload: Dict[str, object]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    def get_profile(
        self,
        *,
        engine: str,
        voice: str,
        language: str,
        machine_signature: str = "",
    ) -> Optional[Dict[str, object]]:
        payload = self._load()
        profiles = payload.get("profiles", {})
        if not isinstance(profiles, dict):
            return None
        entry = profiles.get(self._key(engine, voice, language, machine_signature))
        if entry is None and machine_signature:
            # Backward compatibility with pre-signature profiles.
            entry = profiles.get(self._key(engine, voice, language, ""))
        if entry is None and not machine_signature:
            # Compatibility with machine-scoped profiles when callers omit signature.
            entry = profiles.get(self._key(engine, voice, language, "generic"))
        if isinstance(entry, dict):
            return entry
        return None

    def upsert_profile(
        self,
        *,
        engine: str,
        voice: str,
        language: str,
        machine_signature: str = "",
        chars_per_second: float,
        params: Dict[str, object],
        min_improvement_ratio: float = 0.03,
    ) -> bool:
        payload = self._load()
        profiles = payload.setdefault("profiles", {})
        if not isinstance(profiles, dict):
            profiles = {}
            payload["profiles"] = profiles

        key = self._key(engine, voice, language, machine_signature)
        existing = profiles.get(key) if isinstance(profiles.get(key), dict) else None
        previous_cps = float((existing or {}).get("best_chars_per_second", 0.0) or 0.0)
        sample_count = int((existing or {}).get("sample_count", 0) or 0) + 1
        cps = max(0.0, float(chars_per_second or 0.0))

        should_replace = existing is None or cps >= previous_cps * (1.0 + min_improvement_ratio)
        if not should_replace:
            # Keep best params but update metadata to reflect more observations.
            existing["sample_count"] = sample_count
            existing["last_seen_chars_per_second"] = cps
            existing["updated_at"] = time.time()
            profiles[key] = existing
            self._save(payload)
            return False

        profiles[key] = {
            "engine": (engine or "").lower(),
            "voice": voice or "",
            "language": (language or "").lower(),
            "machine_signature": (machine_signature or "").lower(),
            "best_chars_per_second": cps,
            "last_seen_chars_per_second": cps,
            "sample_count": sample_count,
            "params": dict(params or {}),
            "updated_at": time.time(),
        }
        self._save(payload)
        return True


__all__ = ["PerformanceProfileStore"]
