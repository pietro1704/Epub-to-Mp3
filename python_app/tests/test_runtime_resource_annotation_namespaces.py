"""Exercise real resource annotations and metrics after owner extraction."""

import json
import weakref
from typing import List, Optional, get_type_hints

from src.adaptive_performance import AdaptivePerformanceController
from src.auto_tuner import AutoTuner
from src.converter_lifecycle import ConverterLifecycle
from src.hardware_detector import HardwareProfile
from src.segment_metrics_reports import SegmentMetricsReports
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
        assert function.__globals__ is server.__dict__, name
    assert server._JOB_WORKERS >= 1
