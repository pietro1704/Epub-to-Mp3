from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src import session_logger
from src._metrics_report_mixin import _MetricsReportMixin
from src.chapter_identity import assign_chapter_identities, chapter_label
from src.converter import AudioConverter
from src.ebook_reader import Chapter


def test_assign_chapter_identities_preserves_hierarchical_labels() -> None:
    chapters = [
        Chapter("4.1", "The First Scene", "OEBPS/part.xhtml#s1", "text one"),
        Chapter("4.2", "The Second Scene", "OEBPS/part.xhtml#s2", "text two"),
    ]

    assigned = assign_chapter_identities(chapters)

    assert assigned is chapters
    assert chapters[0].stable_id != chapters[1].stable_id
    assert chapter_label(chapters[0], 1) == "4.1"
    assert chapter_label(chapters[1], 2) == "4.2"
    assert chapters[0].stable_id.startswith("ch-")


def test_chapter_identity_is_stable_when_chapter_objects_are_recreated() -> None:
    first = Chapter("7.3", "A repeated title", "text/chapter.xhtml#one", "first")
    second = Chapter("7.3", "A repeated title", "text/chapter.xhtml#one", "first")

    assign_chapter_identities([first])
    assign_chapter_identities([second])

    assert first.stable_id == second.stable_id


def test_duplicate_identity_inputs_get_deterministic_occurrence_suffixes() -> None:
    chapters = [
        Chapter("9", "Same", "same.xhtml", "one"),
        Chapter("9", "Same", "same.xhtml", "two"),
    ]
    assign_chapter_identities(chapters)

    assert chapters[0].stable_id != chapters[1].stable_id
    assert chapters[0].stable_id.endswith("-1")
    assert chapters[1].stable_id.endswith("-2")


def test_log_chapter_perf_writes_stable_identity(tmp_path: Path, monkeypatch) -> None:
    events_path = tmp_path / "events.jsonl"
    monkeypatch.setattr(session_logger, "_EVENTS_FILE", events_path)

    session_logger.log_chapter_perf(
        book_title="Book",
        chapter_index=4,
        chapter_name="Chapter 4",
        chapter_id="ch-abc-1",
        engine="edge",
        elapsed_seconds=2.0,
        char_count=100,
    )

    record = json.loads(events_path.read_text(encoding="utf-8"))
    assert record["chapter_id"] == "ch-abc-1"


def test_runtime_csv_groups_by_stable_id_not_local_chapter_number(tmp_path: Path) -> None:
    class MetricsOnly(_MetricsReportMixin):
        verbose = False

        def _runtime_metrics_path(self, output_dir=None):
            return tmp_path / "_runtime_metrics.jsonl"

    events = [
        {
            "event": "chapter_complete",
            "chapter": 1,
            "chapter_id": "ch-one-1",
            "chapter_label": "4.1",
            "engine": "edge",
            "chars": 100,
            "elapsed_s": 1.0,
            "success": True,
        },
        {
            "event": "chapter_complete",
            "chapter": 1,
            "chapter_id": "ch-two-1",
            "chapter_label": "4.2",
            "engine": "edge",
            "chars": 200,
            "elapsed_s": 2.0,
            "success": True,
        },
    ]
    (tmp_path / "_runtime_metrics.jsonl").write_text(
        "\n".join(json.dumps(item) for item in events) + "\n", encoding="utf-8"
    )

    MetricsOnly()._write_runtime_metrics_csv(tmp_path)

    lines = (tmp_path / "metrics-chapter-engine.csv").read_text(encoding="utf-8").splitlines()
    assert "chapter_id" in lines[0]
    assert len(lines) == 3
    assert "ch-one-1" in lines[1]
    assert "ch-two-1" in lines[2]


def test_converter_binds_edge_metrics_to_runtime_jsonl(tmp_path: Path) -> None:
    converter = AudioConverter()
    engine = SimpleNamespace(metric_callback=None)

    converter._attach_edge_metric_sink(engine, tmp_path)
    engine.metric_callback({"event": "edge_request", "status": "success"})

    record = json.loads((tmp_path / "_segment_metrics.jsonl").read_text(encoding="utf-8"))
    assert record["event"] == "edge_request"
    assert record["status"] == "success"


def test_segment_metrics_summary_aggregates_edge_request_latency(tmp_path: Path) -> None:
    class MetricsOnly(_MetricsReportMixin):
        verbose = False

        def _segment_metrics_path(self, output_dir=None):
            return tmp_path / "_segment_metrics.jsonl"

        @staticmethod
        def _percentile(values, quantile):
            values = sorted(values)
            if not values:
                return 0.0
            index = min(len(values) - 1, int(round((len(values) - 1) * quantile)))
            return float(values[index])

    events = [
        {
            "event": "edge_request",
            "engine": "edge",
            "status": "success",
            "request_ms": 10.0,
            "queue_wait_ms": 2.0,
            "write_ms": 1.0,
            "retry_count": 0,
        },
        {
            "event": "edge_request",
            "engine": "edge",
            "status": "failed",
            "error_category": "timeout",
            "request_ms": 30.0,
            "queue_wait_ms": 5.0,
            "write_ms": 0.0,
            "retry_count": 1,
        },
        {
            "event": "edge_segment_validation",
            "engine": "edge",
            "status": "success",
            "validation_ms": 4.0,
        },
    ]
    (tmp_path / "_segment_metrics.jsonl").write_text(
        "\n".join(json.dumps(item) for item in events) + "\n", encoding="utf-8"
    )

    MetricsOnly()._write_segment_metrics_summary(tmp_path)

    summary = json.loads((tmp_path / "segment-metrics-summary.json").read_text(encoding="utf-8"))
    edge = summary["engines"]["edge"]
    assert edge["request_count"] == 2
    assert edge["failed_requests"] == 1
    assert edge["request_p50_ms"] == 10.0
    assert edge["request_p95_ms"] == 30.0
    assert edge["queue_wait_p95_ms"] == 5.0
    assert edge["validation_count"] == 1
    assert edge["validation_p95_ms"] == 4.0
