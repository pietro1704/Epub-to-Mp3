# -*- coding: utf-8 -*-
"""v0.3.28: telemetry hot path uses append-only JSONL with periodic
compaction instead of full read+rewrite per sample."""

from __future__ import annotations

import json
from pathlib import Path

from src.telemetry import TelemetryRecorder


def _rec(tmp_path: Path) -> TelemetryRecorder:
    rec = TelemetryRecorder(telemetry_file=tmp_path / "tel.json")
    rec.clear()
    return rec


def test_record_sample_appends_to_jsonl(tmp_path):
    rec = _rec(tmp_path)
    rec.record_sample(
        engine="edge",
        voice="x",
        chars=1000,
        synth_seconds=10.0,
        total_seconds=10.0,
        audio_seconds=10.0,
        job_id="j",
        chapter="c",
    )
    assert rec.jsonl_file.exists()
    lines = rec.jsonl_file.read_text(encoding="utf-8").strip().splitlines()
    assert len(lines) == 1
    parsed = json.loads(lines[0])
    assert parsed["engine"] == "edge"
    assert parsed["chars"] == 1000


def test_summary_merges_jsonl_and_consolidated(tmp_path):
    rec = _rec(tmp_path)
    # Pre-seed the consolidated file as if it came from a prior process.
    rec.telemetry_file.write_text(
        json.dumps(
            [
                {
                    "engine": "kokoro",
                    "voice": "x",
                    "chars": 5000,
                    "synth_seconds": 50.0,
                    "total_seconds": 50.0,
                    "audio_seconds": 50.0,
                    "job_id": "old",
                    "chapter": "old",
                    "timestamp": "2026-05-06T00:00:00Z",
                    "language": None,
                }
            ]
        ),
        encoding="utf-8",
    )
    rec.record_sample(
        engine="edge",
        voice="y",
        chars=1000,
        synth_seconds=5.0,
        total_seconds=5.0,
        audio_seconds=5.0,
        job_id="new",
        chapter="new",
    )
    summary = rec.summary()
    assert "kokoro" in summary
    assert "edge" in summary


def test_flush_compacts_jsonl_into_consolidated(tmp_path):
    rec = _rec(tmp_path)
    for i in range(5):
        rec.record_sample(
            engine="edge",
            voice="x",
            chars=1000,
            synth_seconds=5.0,
            total_seconds=5.0,
            audio_seconds=5.0,
            job_id=f"j{i}",
            chapter=f"c{i}",
        )
    # JSONL has the 5 lines; consolidated is empty.
    assert len(rec.jsonl_file.read_text().splitlines()) == 5
    rec.flush()
    # After flush, JSONL is truncated and consolidated has the entries.
    assert rec.jsonl_file.read_text().strip() == ""
    consolidated = json.loads(rec.telemetry_file.read_text())
    assert len(consolidated) == 5


def test_clear_drops_both_files(tmp_path):
    rec = _rec(tmp_path)
    rec.record_sample(
        engine="edge",
        voice="x",
        chars=1000,
        synth_seconds=5.0,
        total_seconds=5.0,
        audio_seconds=5.0,
        job_id="j",
        chapter="c",
    )
    rec.flush()
    assert rec.telemetry_file.exists()
    rec.clear()
    assert not rec.telemetry_file.exists()
    assert not rec.jsonl_file.exists()
