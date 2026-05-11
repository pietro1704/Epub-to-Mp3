"""Regression: HealthMonitor start/stop logs must be in English.

CLAUDE.md "Language Policy" requires all log messages in English.
The sidecar startup log used to read "[HealthMonitor] Iniciado",
which surfaced in user-visible stdout when running the desktop app.
"""

from __future__ import annotations

import io
from contextlib import redirect_stdout

from python_app.health_monitor import HealthMonitor


def test_start_and_stop_log_in_english() -> None:
    monitor = HealthMonitor(interval_seconds=0.05)

    buf = io.StringIO()
    with redirect_stdout(buf):
        monitor.start()
        monitor.stop()
    out = buf.getvalue()

    assert "Started" in out, out
    assert "Stopped" in out, out
    # Guard against regressions to the Portuguese strings.
    assert "Iniciado" not in out, out
    assert "Parado" not in out, out
