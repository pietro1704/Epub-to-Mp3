# -*- coding: utf-8 -*-
"""Helpers to detect whether Piper can run on this system."""

from __future__ import annotations

import os
import shutil
import subprocess

from .numpy_guard import is_numpy_safe_environment

_piper_binary_result: bool | None = None


def _piper_binary_works() -> bool:
    """Check if the piper CLI binary actually runs. Cached per process."""
    global _piper_binary_result
    if _piper_binary_result is not None:
        return _piper_binary_result

    piper_bin = shutil.which("piper")
    if not piper_bin:
        _piper_binary_result = False
        return False

    try:
        proc = subprocess.run(
            [piper_bin, "--help"],
            capture_output=True,
            timeout=5,
        )
        _piper_binary_result = proc.returncode == 0
    except Exception:
        _piper_binary_result = False

    return _piper_binary_result


def is_piper_supported_environment() -> bool:
    """
    Return True when Piper TTS can run on this system.

    First checks env overrides, then tries running the piper binary directly.
    Falls back to the NumPy/Accelerate safety check only if the binary test
    is inconclusive.
    """
    force_disable = os.getenv("DISABLE_PIPER", "").strip().lower()
    if force_disable in {"1", "true", "yes", "on"}:
        return False

    force_enable = os.getenv("ENABLE_PIPER", "").strip().lower()
    if force_enable in {"1", "true", "yes", "on"}:
        return True

    if _piper_binary_works():
        return True

    return is_numpy_safe_environment()


__all__ = ["is_piper_supported_environment"]
