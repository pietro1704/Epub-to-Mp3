"""Health monitor compatibility and lock ownership regression tests."""

import io
import json
import subprocess
import sys
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from python_app import health_monitor as health
from python_app.health_monitor_adapter import SystemMonitorAdapter


def _snapshot():
    return health.HealthSnapshot(
        timestamp=100.0, cpu_percent=12.0, memory_percent=25.0, memory_mb=256.0,
        gpu_available=False, gpu_memory_used_mb=0.0, gpu_memory_total_mb=0.0,
        gpu_utilization=0.0, heap_status="healthy", gc_collections={}, thread_count=3,
        alerts=[],
    )


def test_adapter_keeps_identity_and_legacy_units():
    monitor = Mock()
    monitor.get_latest_snapshot.return_value = _snapshot()
    assert health.SystemMonitorAdapter is SystemMonitorAdapter
    adapter = health.SystemMonitorAdapter(monitor)
    with patch("os.cpu_count", return_value=8):
        latest = adapter.latest()
    assert latest == {
        "cpu": {"percent": 12.0, "count": 8},
        "memory": {"percent": 25.0, "available": 768 * 1024 * 1024, "total": 1024 * 1024 * 1024},
        "disk": {"percent": 0},
    }
    adapter.start()
    adapter.stop()
    monitor.start.assert_called_once_with()
    monitor.stop.assert_called_once_with()


def test_adapter_missing_snapshot_and_zero_percent_remain_safe():
    monitor = Mock()
    adapter = health.SystemMonitorAdapter(monitor)
    monitor.get_latest_snapshot.return_value = None
    assert adapter.latest() == {}
    monitor.get_latest_snapshot.return_value = SimpleNamespace(
        memory_percent=0.0, memory_mb=0.0, cpu_percent=0.0
    )
    assert adapter.latest()["memory"] == {"percent": 0.0, "available": 0, "total": 0}


def test_export_report_completes_without_reentering_monitor_lock(tmp_path):
    # A child process bounds the historical deadlock and cannot hang the CI worker.
    root = Path(__file__).resolve().parents[2]
    script = """
import sys
from pathlib import Path
from python_app.health_monitor import HealthMonitor
monitor = HealthMonitor()
monitor.export_report(Path(sys.argv[1]))
"""
    report = tmp_path / "health.json"
    result = subprocess.run(
        [sys.executable, "-c", script, str(report)], cwd=root,
        capture_output=True, text=True, timeout=10, check=False,
    )
    assert result.returncode == 0, result.stderr
    exported = json.loads(report.read_text())
    assert exported["summary"] == {}
    assert exported["snapshots_count"] == 0
    assert exported["recent_alerts"] == []


def test_export_and_summary_share_snapshot_state_under_one_lock(tmp_path):
    monitor = health.HealthMonitor()
    monitor._snapshots.append(_snapshot())
    monitor._alerts.append(health.HealthAlert(100.0, "warning", "memory", "high", {}))
    # Detect accidental nested acquisition immediately instead of hanging the test.
    class OneOwnerLock:
        active = False

        def __enter__(self):
            assert not self.active, "monitor lock acquired recursively"
            self.active = True

        def __exit__(self, *_):
            self.active = False

    monitor._lock = OneOwnerLock()
    expected = monitor.get_stats_summary()
    with redirect_stdout(io.StringIO()):
        monitor.export_report(tmp_path / "health.json")
    report = json.loads((tmp_path / "health.json").read_text())
    assert report["summary"]["current"] == expected["current"]
    assert report["summary"]["total_alerts"] == 1
    assert report["snapshots_count"] == 1
