"""Shared environment-variable coercion helpers.

Extracted from four byte-identical copies in converter.py,
_engine_selection_mixin.py, _edge_throttle_mixin.py, and
_validation_mixin.py — see docs/plans/uikit-performance-migration.md-style
SOLID audit, 2026-07-23.
"""

import os


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default
