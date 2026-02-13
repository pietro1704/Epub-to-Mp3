# -*- coding: utf-8 -*-
"""Helpers to detect whether Piper (NumPy) can be safely imported."""

from __future__ import annotations

import os

from .numpy_guard import is_numpy_safe_environment


def is_piper_supported_environment() -> bool:
    """
    Return True when it is safe to import Piper/NuPy.

    Intel macOS builds that rely on Apple's Accelerate backend frequently crash
    with SIGFPE as soon as NumPy is imported. Disable Piper there unless the
    user explicitly forces it via ENABLE_PIPER=1.
    """

    force_disable = os.getenv("DISABLE_PIPER", "").strip().lower()
    if force_disable in {"1", "true", "yes", "on"}:
        return False

    force_enable = os.getenv("ENABLE_PIPER", "").strip().lower()
    if force_enable in {"1", "true", "yes", "on"}:
        return True

    return is_numpy_safe_environment()


__all__ = ["is_piper_supported_environment"]
