"""Exercise real resource annotations and metrics after owner extraction."""

import asyncio
import inspect
import json
import weakref
from types import SimpleNamespace
from typing import List, Optional, get_type_hints
from unittest.mock import Mock

import pytest
from src.adaptive_performance import AdaptivePerformanceController
from src.auto_tuner import AutoTuner
from src.converter_lifecycle import ConverterLifecycle
from src.hardware_detector import HardwareProfile
from src.segment_metrics_reports import SegmentMetricsReports
from src.server_runtime_binding import bind_server_function
from src.synthesis_tracker import SynthesisTracker
from src.tts.edge_engine_initialization import EdgeEngineInitialization


def test_converter_resource_annotations_resolve_without_constructing_tts():
    hints = get_type_hints(ConverterLifecycle)
    assert hints["hardware_profile"] == Optional[HardwareProfile]
    assert hints["_auto_tuner"] == Optional[AutoTuner]
    assert hints["_adaptive_controller"] == Optional[AdaptivePerformanceController]
    assert hints["_thread_pools"] == List[weakref.ref]


def test_edge_tracker_annotation_resolves_without_constructing_provider():
    assert get_type_hints(EdgeEngineInitialization)["_synthesis_tracker"] == Optional[SynthesisTracker]


def test_metrics_dashboard_renders_real_timeline_lists(tmp_path):
    metrics = tmp_path / "segment-metrics.jsonl"
    events = [
        {"event": "segment_success", "engine": "piper", "ts": stamp, "cps": cps}
        for stamp, cps in [(1, 80), (2, 100)]
    ]
    metrics.write_text("\n".join(json.dumps(event) for event in events), encoding="utf-8")
    summary = {
        "engines": {
            "piper": {
                "segments": 2,
                "avg_chars_per_second": 90,
                "p95_chars_per_second": 100,
                "jitter_ratio": 1.25,
            }
        },
        "event_counts": {},
    }
    (tmp_path / "segment-metrics-summary.json").write_text(
        json.dumps(summary), encoding="utf-8"
    )
    SegmentMetricsReports(metrics).write_dashboard()
    dashboard = (tmp_path / "segment-metrics-dashboard.html").read_text(encoding="utf-8")
    assert "<svg" in dashboard
    assert "<polyline" in dashboard
    assert "piper" in dashboard


def test_server_bootstrap_contract_binds_real_facade_objects(monkeypatch):
    monkeypatch.setenv("EDGE_NETWORK_PROBE", "0")
    import server
    from fastapi import FastAPI

    assert isinstance(server.app, FastAPI)
    assert get_type_hints(server._lifespan.__wrapped__)["app"] is FastAPI
    assert server.output_dir == server.OUTPUT_DIR
    for name in ("_job_worker", "_periodic_job_cleanup", "_load_restart_marker",
                 "_clear_restart_marker", "_resume_pending_jobs", "_job_watchdog",
                 "_hf_keepalive", "_has_active_jobs"):
        function = getattr(server, name)
        assert callable(function), name
        captured = inspect.getclosurevars(function).nonlocals
        assert captured["runtime"] is server, name
        assert captured["implementation"] is function.__wrapped__, name
        assert function.__module__ == server.__name__, name
        assert "_runtime" not in inspect.signature(function).parameters, name
    assert server._JOB_WORKERS >= 1

    monkeypatch.setattr(server, "jobs", {})
    monkeypatch.setattr(server, "_job_queue", None)
    assert server._has_active_jobs() is False
    monkeypatch.setattr(server, "jobs", {"active": {"state": "running"}})
    assert server._has_active_jobs() is True
    monkeypatch.setattr(server, "jobs", {"done": {"state": "finished"}})
    assert server._has_active_jobs() is False


def test_server_binding_preserves_runtime_identity_dynamic_patches_and_errors():
    def implementation(_runtime, value: int, *, offset: int = 1) -> tuple:
        return _runtime, _runtime.callback(value + offset)

    first = SimpleNamespace(__name__="first", callback=lambda value: value * 2)
    second = SimpleNamespace(__name__="second", callback=lambda value: value * 3)
    first_bound = bind_server_function(implementation, first)
    second_bound = bind_server_function(implementation, second)
    assert first_bound(4, offset=2) == (first, 12)
    assert second_bound(4, offset=2) == (second, 18)
    assert list(inspect.signature(first_bound).parameters) == ["value", "offset"]
    assert get_type_hints(first_bound) == {"value": int, "offset": int, "return": tuple}

    failure = RuntimeError("patched runtime callback failed")

    def fail(value):
        raise failure

    first.callback = fail
    with pytest.raises(RuntimeError) as captured:
        first_bound(4)
    assert captured.value is failure
    assert second_bound(4) == (second, 15)


@pytest.mark.asyncio
async def test_server_async_binding_keeps_runtime_identity_and_awaits_result():
    async def implementation(_runtime, value: int) -> tuple:
        await asyncio.sleep(0)
        return _runtime, _runtime.transform(value)

    first = SimpleNamespace(__name__="first", transform=lambda value: value + 1)
    second = SimpleNamespace(__name__="second", transform=lambda value: value + 2)
    first_bound = bind_server_function(implementation, first)
    second_bound = bind_server_function(implementation, second)
    assert inspect.iscoroutinefunction(first_bound)
    assert await first_bound(4) == (first, 5)
    assert await second_bound(4) == (second, 6)
    first.transform = lambda value: value * 3
    assert await first_bound(4) == (first, 12)
    assert await second_bound(4) == (second, 6)

    failure = RuntimeError("async runtime callback failed")

    def fail(value):
        raise failure

    first.transform = fail
    with pytest.raises(RuntimeError) as captured:
        await first_bound(4)
    assert captured.value is failure
    assert await second_bound(4) == (second, 6)


@pytest.mark.asyncio
async def test_server_async_binding_propagates_cancellation_and_runs_cleanup():
    runtime = SimpleNamespace(__name__="cancellation", entered=asyncio.Event(), cleaned=False)

    async def implementation(_runtime):
        _runtime.entered.set()
        try:
            await asyncio.Event().wait()
        finally:
            _runtime.cleaned = True

    bound = bind_server_function(implementation, runtime)
    task = asyncio.create_task(bound())
    try:
        await asyncio.wait_for(runtime.entered.wait(), timeout=1)
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    assert runtime.cleaned is True


def test_voices_endpoint_delegates_to_the_curated_provider_catalog(monkeypatch) -> None:
    monkeypatch.setenv("EDGE_NETWORK_PROBE", "0")
    import server

    catalog = {"edge": [], "piper": [], "auto": []}
    provider = Mock()
    provider.get_voice_suggestions.return_value = catalog
    monkeypatch.setattr(server.tts_factory, "voice_provider", provider)
    route = next(route for route in server.app.routes if route.path == "/api/voices")
    assert route.endpoint is server.list_available_voices
    assert asyncio.run(route.endpoint())["voices"] is catalog
    provider.get_voice_suggestions.assert_called_once_with()
    failure = RuntimeError("catalog unavailable")
    provider.get_voice_suggestions.side_effect = failure
    with pytest.raises(RuntimeError) as captured:
        asyncio.run(route.endpoint())
    assert captured.value is failure
