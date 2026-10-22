# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_environment(_runtime):
    _runtime.os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")
    _runtime.os.environ.setdefault("FORCE_CUDA", "0")
    _runtime.os.environ.setdefault("FORCE_CPU_ONLY", "1")

    # Configure performance optimizations before any imports
    try:
        from performance_config import apply_all_optimizations
        _runtime.apply_all_optimizations = apply_all_optimizations

        _runtime.apply_all_optimizations()
    except ImportError:
        print("⚠️ [Performance] Optimization module not found")
