# -*- coding: utf-8 -*-
"""Helpers to detect whether Spark-TTS (NumPy/transformers) can be safely imported."""

from __future__ import annotations

import os

from .numpy_guard import is_numpy_safe_environment


def is_spark_supported_environment() -> bool:
    """
    Return True when Spark-TTS dependencies (NumPy/transformers) are safe to import.

    Defaults to disabled on Intel macOS to avoid the Accelerate SIGFPE issue.
    """

    force_disable = os.getenv("DISABLE_SPARK_TTS", "").strip().lower()
    if force_disable in {"1", "true", "yes", "on"}:
        return False

    force_enable = os.getenv("ENABLE_SPARK_TTS", "").strip().lower()
    if force_enable in {"1", "true", "yes", "on"}:
        return True

    return is_numpy_safe_environment()


__all__ = ["is_spark_supported_environment"]
