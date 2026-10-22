# -*- coding: utf-8 -*-
"""Request form coercion and canonical locale values."""

from __future__ import annotations

from typing import Optional


def _parse_form_bool(_runtime, value: Optional[str], default: bool = True) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if not normalized:
        return default
    return normalized in {"1", "true", "yes", "on", "enabled"}


def _parse_form_optional_bool(_runtime, value: Optional[str]) -> Optional[bool]:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if not normalized:
        return None
    return normalized in {"1", "true", "yes", "on", "enabled"}


def _parse_form_int(_runtime,
    value: Optional[str],
    *,
    min_value: Optional[int] = None,
    max_value: Optional[int] = None,
) -> Optional[int]:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        parsed = int(text)
    except (TypeError, ValueError):
        return None
    if min_value is not None:
        parsed = max(min_value, parsed)
    if max_value is not None:
        parsed = min(max_value, parsed)
    return parsed


def _parse_form_float(_runtime,
    value: Optional[str],
    *,
    min_value: Optional[float] = None,
    max_value: Optional[float] = None,
) -> Optional[float]:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        parsed = float(text)
    except (TypeError, ValueError):
        return None
    if min_value is not None:
        parsed = max(min_value, parsed)
    if max_value is not None:
        parsed = min(max_value, parsed)
    return parsed


def _normalize_locale(_runtime, value: Optional[str], default: str = "pt") -> str:
    locale_value = (value or default or "pt").split("-", 1)[0].lower()
    if locale_value not in {"pt", "en"}:
        locale_value = "en"
    return locale_value


def _utcnow_iso(_runtime, ) -> str:
    return _runtime.datetime.now(_runtime.timezone.utc).isoformat()


def get_cleanup_interval_seconds(_runtime, ) -> int:
    """Resolve the cleanup interval at call time without reloading the module."""
    default = 60 if _runtime.os.getenv("SPACE_ID") else 300
    raw = _runtime.os.getenv("CLEANUP_INTERVAL_SECONDS", str(default)) or str(default)
    try:
        return max(10, int(raw))
    except ValueError:
        return max(10, default)
