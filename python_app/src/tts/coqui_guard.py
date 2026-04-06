# -*- coding: utf-8 -*-
"""Guard to prevent Coqui imports when NumPy/transformers are unsafe."""

from __future__ import annotations

import os

from .numpy_guard import is_numpy_safe_environment


def is_coqui_supported_environment() -> bool:
    force_disable = os.getenv("DISABLE_COQUI_TTS", "").strip().lower()
    if force_disable in {"1", "true", "yes", "on"}:
        return False

    force_enable = os.getenv("ENABLE_COQUI_TTS", "").strip().lower()
    if force_enable in {"1", "true", "yes", "on"}:
        return True

    if not is_numpy_safe_environment():
        return False

    # Coqui XTTS requires BeamSearchScorer which was removed from the public
    # transformers API in newer releases.  Probe the import so we fail fast at
    # startup instead of crashing mid-conversion.
    try:
        from transformers import BeamSearchScorer  # noqa: F401
    except ImportError:
        return False

    return True


__all__ = ["is_coqui_supported_environment"]
