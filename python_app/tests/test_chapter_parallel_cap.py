# -*- coding: utf-8 -*-
"""Chapter-parallel cap reacts to Edge chunk-size shrinkage.

When the per-segment auto-tuner shrinks Edge chunk_chars after a stall, every
chapter generates many more requests. Running 15+ chapters in parallel under
that condition saturates outbound bandwidth. The chapter-level tuner must back
off proportionally.
"""

from __future__ import annotations

from unittest.mock import patch

from python_app.src._edge_throttle_mixin import _EdgeThrottleMixin
from python_app.src.tts import edge_engine as edge_module


class TestChapterCapFromEdgeChunk:
    def test_no_cap_when_chunk_healthy(self):
        with patch.object(edge_module, "_edge_current_chunk_size", 10000):
            assert _EdgeThrottleMixin._chapter_cap_from_edge_chunk() is None

    def test_cap_8_when_chunk_moderately_reduced(self):
        with patch.object(edge_module, "_edge_current_chunk_size", 6000):
            assert _EdgeThrottleMixin._chapter_cap_from_edge_chunk() == 8

    def test_cap_4_when_chunk_severely_reduced(self):
        with patch.object(edge_module, "_edge_current_chunk_size", 4000):
            assert _EdgeThrottleMixin._chapter_cap_from_edge_chunk() == 4

    def test_no_cap_when_chunk_unset(self):
        with patch.object(edge_module, "_edge_current_chunk_size", 0):
            assert _EdgeThrottleMixin._chapter_cap_from_edge_chunk() is None
