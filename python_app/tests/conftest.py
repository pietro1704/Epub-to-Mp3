# -*- coding: utf-8 -*-
"""Project-wide test fixtures.

Adds an autouse fixture that resets the once-per-process cleanup gates
introduced in v0.3.24/v0.3.25/v0.3.26 so cross-test pollution can't
mask regressions. Each test runs against fresh state.
"""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _reset_lazy_cleanup_gates():
    """Reset module-level "cleanup ran" flags before each test.

    These gates exist so the lazy GC of stale cache entries runs at most
    once per CLI/server start. In tests they leak across cases — a test
    that triggers a cleanup leaves the flag set, hiding the cleanup path
    from later tests. Reset before yielding so each test sees a fresh
    process-equivalent state.

    Restored on teardown so the next test starts clean as well, even if
    a test mutated the flag mid-run.
    """
    # ebook_reader._TOC_DISK_CACHE_CLEANED
    try:
        from src import ebook_reader as _eb

        _eb_prev = _eb._TOC_DISK_CACHE_CLEANED
        _eb._TOC_DISK_CACHE_CLEANED = False
    except Exception:
        _eb = None
        _eb_prev = False

    # CacheManager._TEXT_CACHE_CLEANED
    try:
        from src.cache_manager import CacheManager as _CM

        _cm_prev = _CM._TEXT_CACHE_CLEANED
        _CM._TEXT_CACHE_CLEANED = False
    except Exception:
        _CM = None
        _cm_prev = False

    yield

    if _eb is not None:
        _eb._TOC_DISK_CACHE_CLEANED = _eb_prev
    if _CM is not None:
        _CM._TEXT_CACHE_CLEANED = _cm_prev
