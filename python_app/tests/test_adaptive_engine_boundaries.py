"""Adaptive configuration/tuning/resource seams preserve runtime overrides and state."""

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from src import _edge_throttle_mixin as facade
from src import segment_adaptive_tuning as tuning


class _Host(facade._EdgeThrottleMixin):
    verbose = False

    def __init__(self):
        self._adaptive_checkpoint_enabled = True
        self._adaptive_checkpoint_dirty = 3
        self._segment_adaptive_state = {"engine_cps": {"edge": [100.0]}, "last_adjustment": 10.0}
        self._engine_resource_budget = {"edge": {"cap": 4}}
        self._auto_ab_counter = 7
        self._parallel_state = {"ceiling": 4, "current": 4}
        self._resource_budget_enabled = True
        self._resource_budget_min_share = 0.5
        self._append_runtime_metric = Mock()


def test_stage_defaults_still_read_replaceable_public_constants(monkeypatch):
    monkeypatch.setattr(facade, "STAGE_PIPELINE_ENABLED_DEFAULT", False)
    monkeypatch.setattr(facade, "STAGE_PIPELINE_DEPTH_DEFAULT", 9)
    monkeypatch.setattr("os.cpu_count", lambda: 2)
    config = SimpleNamespace(extra={})
    assert not _Host._is_stage_pipeline_enabled(config)
    assert _Host._stage_pipeline_depth(config) == 9


def test_adaptive_checkpoint_roundtrip_updates_existing_segment_state(tmp_path):
    host = _Host()
    host._save_adaptive_state_checkpoint(tmp_path)
    assert host._adaptive_checkpoint_dirty == 0
    restored = _Host()
    original = restored._segment_adaptive_state
    restored._segment_adaptive_state.clear()
    restored._load_adaptive_state_checkpoint(tmp_path)
    assert restored._segment_adaptive_state is original
    assert restored._segment_adaptive_state["engine_cps"] == {"edge": [100.0]}
    assert restored._auto_ab_counter == 7
    restored._append_runtime_metric.assert_called_once_with({"event": "adaptive_state_restored"})


def test_resource_budget_pressure_uses_host_pool_and_reports_explicit_guard(monkeypatch):
    host = _Host()
    host._segment_adaptive_state["engine_cps"] = {}
    pool = Mock()
    snapshot = SimpleNamespace(ram_gb=0.2, cpu_percent=20.0)
    monkeypatch.setenv("CHAPTER_PARALLEL_COUNT_SOURCE", "explicit")
    for _ in range(2):
        host._apply_engine_resource_budget(engine_label="edge", snapshot=snapshot, engine_pool=pool)
    assert host._parallel_state["current"] == 3
    pool.update_parallel_slots.assert_called_once_with(3)
    metric = host._append_runtime_metric.call_args.args[0]
    assert metric["engine"] == "edge"
    assert metric["override_bypassed_guard"] is True


def test_adaptive_checkpoint_io_failure_and_cancellation_keep_state(tmp_path, monkeypatch):
    host = _Host()
    with monkeypatch.context() as context:
        context.setattr(Path, "write_text", Mock(side_effect=OSError("write failed")))
        host._save_adaptive_state_checkpoint(tmp_path)
    assert host._adaptive_checkpoint_dirty == 3
    host._save_adaptive_state_checkpoint(tmp_path)
    with monkeypatch.context() as context:
        context.setattr(Path, "read_text", Mock(side_effect=KeyboardInterrupt))
        with pytest.raises(KeyboardInterrupt):
            host._load_adaptive_state_checkpoint(tmp_path)
    assert host._segment_adaptive_state["engine_cps"] == {"edge": [100.0]}


def test_resource_probe_failures_are_best_effort_but_cancellation_propagates(monkeypatch):
    monkeypatch.setattr(tuning.psutil, "cpu_percent", Mock(side_effect=OSError("cpu probe")))
    monkeypatch.setattr(tuning.psutil, "virtual_memory", Mock(side_effect=OSError("ram probe")))
    snapshot = _Host()._resource_snapshot()
    assert snapshot.cpu_percent == 0.0 and snapshot.ram_gb == 0.0
    monkeypatch.setattr(tuning.psutil, "cpu_percent", Mock(side_effect=KeyboardInterrupt))
    with pytest.raises(KeyboardInterrupt):
        _Host()._resource_snapshot()
