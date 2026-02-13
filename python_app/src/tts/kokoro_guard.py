# -*- coding: utf-8 -*-
"""Helpers to safely gate Kokoro imports on environments where NumPy crashes."""

from __future__ import annotations

import os
import platform
import sys
from typing import Callable, Optional


def is_kokoro_supported_environment() -> bool:
    """
    Return True when it is safe to import Kokoro/NumPy.

    NumPy wheels compiled against Apple's Accelerate frequently crash with
    ``SIGFPE`` on Intel macOS. Kokoro depends on NumPy, so we disable it
    by default on those hosts unless the user explicitly forces it on.
    """

    force_disable = os.getenv("DISABLE_KOKORO", "").strip().lower()
    if force_disable in {"1", "true", "yes", "on"}:
        return False

    force_enable = os.getenv("ENABLE_KOKORO", "").strip().lower()
    if force_enable in {"1", "true", "yes", "on"}:
        return True

    if sys.platform != "darwin":
        return True

    arch = platform.machine().lower()
    # Intel macOS + Accelerate-backed NumPy is notoriously unstable
    return arch not in {"x86_64", "i386"}


def load_kokoro_supports_language() -> Optional[Callable[[Optional[str]], bool]]:
    """Attempt to import ``kokoro_supports_language`` only if environment allows."""

    if not is_kokoro_supported_environment():
        return None

    try:
        from .kokoro_engine import kokoro_supports_language
    except Exception:
        return None
    return kokoro_supports_language


__all__ = ["is_kokoro_supported_environment", "load_kokoro_supports_language"]
