"""Segment report writer extraction keeps outputs, failure and cancellation behavior."""

import csv
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import Mock

import pytest
from src._metrics_report_mixin import _MetricsReportMixin


class _Reports(_MetricsReportMixin):
    verbose = True

    def __init__(self, journal):
        self.journal = journal
        self._percentile = Mock(side_effect=lambda values, q: min(values) if values else 0.0)

    def _segment_metrics_path(self, output_dir=None):
        return self.journal


def _event():
    return {"event": "segment_success", "engine": "edge", "chapter": "7.13", "segment_chars": 1000, "elapsed_s": 2.0}


def test_segment_journal_produces_identity_preserving_summary_csv_and_dashboard(tmp_path):
    journal = tmp_path / "segments.jsonl"
    journal.write_text("invalid-json\n" + json.dumps(_event()) + "\n", encoding="utf-8")
    reports = _Reports(journal)
    reports._write_segment_metrics_summary()
    reports._write_segment_metrics_csv()
    reports._write_segment_metrics_dashboard()
    summary = json.loads((tmp_path / "segment-metrics-summary.json").read_text())
    assert summary["event_counts"] == {"segment_success": 1}
    assert summary["engines"]["edge"]["segments"] == 1
    reports._percentile.assert_called()
    with (tmp_path / "segment-metrics-engine-chapter.csv").open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert rows[0]["chapter"] == "7.13"
    assert rows[0]["total_chars"] == "1000"
    assert "7.13" in (tmp_path / "segment-metrics-dashboard.html").read_text()


def test_missing_journal_does_not_create_reports(tmp_path):
    reports = _Reports(tmp_path / "missing.jsonl")
    reports._write_segment_metrics_summary()
    reports._write_segment_metrics_csv()
    reports._write_segment_metrics_dashboard()
    assert list(tmp_path.iterdir()) == []


def test_invalid_numeric_metrics_follow_existing_best_effort_failure(tmp_path):
    journal = tmp_path / "segments.jsonl"
    event = _event()
    event["segment_chars"] = "invalid"
    journal.write_text(json.dumps(event), encoding="utf-8")
    reports = _Reports(journal)
    with redirect_stdout(io.StringIO()) as output:
        reports._write_segment_metrics_summary()
    assert "Failed to write segment metrics summary" in output.getvalue()
    assert not (tmp_path / "segment-metrics-summary.json").exists()


def test_segment_report_cancellation_propagates(tmp_path, monkeypatch):
    journal = tmp_path / "segments.jsonl"
    journal.write_text(json.dumps(_event()), encoding="utf-8")
    reports = _Reports(journal)
    with monkeypatch.context() as context:
        context.setattr(Path, "open", Mock(side_effect=KeyboardInterrupt))
        with pytest.raises(KeyboardInterrupt):
            reports._write_segment_metrics_summary()
    assert not (tmp_path / "segment-metrics-summary.json").exists()
