# -*- coding: utf-8 -*-
"""Shared helpers to determine if NumPy can load safely."""

from __future__ import annotations

import platform
import sys


def is_numpy_safe_environment() -> bool:
    """Return True when NumPy can be imported without triggering Accelerate SIGFPE."""
    if sys.platform != "darwin":
        return True
    arch = platform.machine().lower()
    return arch not in {"x86_64", "i386"}


__all__ = ["is_numpy_safe_environment"]
