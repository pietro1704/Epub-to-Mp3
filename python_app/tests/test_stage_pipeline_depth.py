# -*- coding: utf-8 -*-
"""v0.3.28: stage_pipeline_depth scales with cpu_count when no explicit
override is set, instead of the previous fixed default of 2."""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import patch

from src._edge_throttle_mixin import (
    STAGE_PIPELINE_DEPTH_DEFAULT,
    _EdgeThrottleMixin,
)


class _Mixin(_EdgeThrottleMixin):
    pass


def test_depth_uses_explicit_override_when_set():
    cfg = SimpleNamespace(extra={"stage_pipeline_depth": 12})
    assert _Mixin._stage_pipeline_depth(cfg) == 12


def test_depth_floors_at_one_when_override_below_one():
    cfg = SimpleNamespace(extra={"stage_pipeline_depth": 0})
    assert _Mixin._stage_pipeline_depth(cfg) == 1


def test_depth_uses_default_for_missing_override():
    cfg = SimpleNamespace(extra={})
    with patch("os.cpu_count", return_value=8):
        depth = _Mixin._stage_pipeline_depth(cfg)
    # cpu=8 → max(default, min(8, 8)) = 8 (or default if higher).
    assert depth == max(STAGE_PIPELINE_DEPTH_DEFAULT, 8)


def test_depth_caps_at_eight_on_high_core_machines():
    cfg = SimpleNamespace(extra={})
    with patch("os.cpu_count", return_value=32):
        depth = _Mixin._stage_pipeline_depth(cfg)
    assert depth == max(STAGE_PIPELINE_DEPTH_DEFAULT, 8)


def test_depth_defaults_when_cpu_count_unavailable():
    cfg = SimpleNamespace(extra={})
    with patch("os.cpu_count", return_value=None):
        depth = _Mixin._stage_pipeline_depth(cfg)
    # Falls through to cpu=4 default → max(default, 4).
    assert depth == max(STAGE_PIPELINE_DEPTH_DEFAULT, 4)


def test_depth_returns_default_on_invalid_override_type():
    cfg = SimpleNamespace(extra={"stage_pipeline_depth": "not a number"})
    assert _Mixin._stage_pipeline_depth(cfg) == STAGE_PIPELINE_DEPTH_DEFAULT
