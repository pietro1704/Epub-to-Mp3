"""Controlled export fixtures test the gate, not product performance."""

import copy
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from uuid import UUID

import pytest

from scripts import performance_evidence_gate as gate


def capture(root, index=0, cache="cold", reader_ms=100):
    ids = {name: str(UUID(int=index * 4 + n)) for n, name in enumerate(("open", "play", "seek"), 1)}
    context = {"documentKind": "epub", "cacheClass": "cold" if cache == "cold" else "prepared_disk"}
    journeys = []
    for name, kind, records in (
        (
            "open",
            "book_open",
            [
                ("open_requested", 0),
                ("readable_content", reader_ms),
                ("controls_usable", reader_ms),
            ],
        ),
        (
            "play",
            "progressive_playback",
            [("play_requested", 0), ("audio_queued", 50), ("audio_audible", 150)],
        ),
        ("seek", "seek", [("seek_requested", 0), ("seek_target_reached", 75)]),
    ):
        journeys.append(
            {
                "id": ids[name],
                "kind": kind,
                "context": context,
                "records": [
                    {"transition": t, "elapsedNanoseconds": ms * 1_000_000} for t, ms in records
                ],
            }
        )
    payload = json.dumps(journeys).encode()
    digest = hashlib.sha256(payload).hexdigest()
    (root / "artifacts").mkdir(exist_ok=True)
    (root / "artifacts" / f"{digest}.json").write_bytes(payload)
    return {
        "client": "apple",
        "runner": "iPhone 16e",
        "execution_environment": "physical_device",
        "revision": "b" * 40,
        "run_id": str(UUID(int=index + 10_000)),
        "source_sha256": digest,
        "journeys": ids,
        "corpus": {"kind": "epub", "sha256": "a" * 64, "size_bytes": 1000, "page_count": 10},
        "cache_state": cache,
        "resource_policy": "normal",
    }


def bundle(root, captures):
    path = root / "evidence.json"
    path.write_text(json.dumps({"schema_version": 2, "captures": captures}))
    return path


def report(path, **kwargs):
    return gate.evaluate(
        gate.load_evidence(path).samples, clients=("apple",), corpora=("epub",), **kwargs
    )


@pytest.mark.parametrize("dimension", ["clients", "corpora", "cache_states"])
def test_empty_selection_cannot_pass(dimension):
    with pytest.raises(gate.EvidenceError, match="non-empty"):
        gate.evaluate([], **{dimension: ()})


@pytest.mark.parametrize("count", [0, 1, 19, True, 20.5])
def test_cannot_lower_twenty_repetition_requirement(count):
    with pytest.raises(gate.EvidenceError):
        gate.evaluate([], required_samples=count)


def test_import_derives_boundaries_and_preserves_source_metadata(tmp_path):
    sample = capture(tmp_path)
    result = report(bundle(tmp_path, [sample]))
    cold = result["buckets"][0]
    assert cold["sample_count"] == 1
    assert cold["corpus_sha256"] == "a" * 64
    assert cold["runner"] == "iPhone 16e"
    assert cold["resource_policy"] == "normal"
    assert cold["boundaries"]["audio_queued"]["p95_ms"] == 50
    assert cold["boundaries"]["audio_audible"]["p95_ms"] == 150
    assert cold["boundaries"]["seek_target_reached"]["p95_ms"] == 75
    assert cold["sources"] == [sample["source_sha256"]]
    assert result["status"] == "pending"


def test_reused_journeys_and_process_runs_are_rejected(tmp_path):
    first = capture(tmp_path)
    duplicate = copy.deepcopy(first)
    duplicate["run_id"] = str(UUID(int=99_999))
    with pytest.raises(gate.EvidenceError, match="reused"):
        gate.load_evidence(bundle(tmp_path, [first, duplicate]))
    second = capture(tmp_path, 1)
    second["run_id"] = first["run_id"]
    with pytest.raises(gate.EvidenceError, match="reused"):
        gate.load_evidence(bundle(tmp_path, [first, second]))


@pytest.mark.parametrize("dimension", ["corpus", "runner", "resource_policy", "revision"])
def test_capture_conditions_cannot_pool_repetitions(tmp_path, dimension):
    samples = [capture(tmp_path, i) for i in range(20)]
    for sample in samples[10:]:
        if dimension == "corpus":
            sample["corpus"]["sha256"] = "c" * 64
        else:
            sample[dimension] = {
                "runner": "iPad",
                "resource_policy": "resource_constrained",
                "revision": "d" * 40,
            }[dimension]
    result = report(bundle(tmp_path, samples), cache_states=("cold",))
    assert [b["sample_count"] for b in result["buckets"]] == [10, 10]
    assert result["status"] == "pending"
    assert len(result["missing"]) == 2


@pytest.mark.parametrize("field", ["size_bytes", "page_count"])
@pytest.mark.parametrize("value", [0.1, 1.5, True, 0])
def test_corpus_counts_require_positive_integers(tmp_path, field, value):
    sample = capture(tmp_path)
    sample["corpus"][field] = value
    with pytest.raises(gate.EvidenceError, match="positive integer"):
        gate.load_evidence(bundle(tmp_path, [sample]))


def test_source_hash_is_verified(tmp_path):
    sample = capture(tmp_path)
    (tmp_path / "artifacts" / f"{sample['source_sha256']}.json").write_text("[]")
    with pytest.raises(gate.EvidenceError, match="digest"):
        gate.load_evidence(bundle(tmp_path, [sample]))


def test_observations_cannot_substitute_for_release_evidence(tmp_path):
    samples = [
        capture(tmp_path, i, cache=state)
        for state, start in (("cold", 0), ("relaunch_warm", 20))
        for i in range(start, start + 20)
    ]
    result = report(bundle(tmp_path, samples))
    assert result["observations_status"] == "passed"
    assert result["status"] == "pending"
    assert "conversion_output_integrity_cli" in result["pending_requirements"]
    assert "automated_collection_lifecycle" in result["pending_requirements"]


def test_budget_failure_names_boundary_despite_missing_other_evidence(tmp_path):
    samples = [capture(tmp_path, i, cache="relaunch_warm", reader_ms=250 + i) for i in range(20)]
    result = report(bundle(tmp_path, samples))
    assert result["status"] == "failed"
    assert result["buckets"][1]["boundaries"]["reader_usable"]["p50_ms"] == 259.5
    assert result["optimization_queue"][0]["boundary"] == "reader_usable"
    assert result["optimization_queue"][0]["p95_ms"] == 268.05


def test_cold_and_warm_require_matching_corpus_conditions(tmp_path):
    samples = [
        capture(tmp_path, i, cache=state)
        for state, start in (("cold", 0), ("relaunch_warm", 20))
        for i in range(start, start + 20)
    ]
    for sample in samples[20:]:
        sample["corpus"]["sha256"] = "c" * 64
    result = report(bundle(tmp_path, samples))
    assert result["observations_status"] == "pending"
    assert len(result["missing"]) == 2


def test_budget_uses_unrounded_percentile(tmp_path):
    samples = [capture(tmp_path, i, cache="relaunch_warm", reader_ms=200) for i in range(20)]
    loaded = list(gate.load_evidence(bundle(tmp_path, samples)).samples)
    for sample in loaded:
        sample.boundaries_ms["reader_usable"] = 200.000001
    result = gate.evaluate(loaded, clients=("apple",), corpora=("epub",))
    assert result["status"] == "failed"


def test_strict_cli_reports_pending(tmp_path, capsys):
    assert gate.main([str(bundle(tmp_path, [capture(tmp_path)])), "--strict"]) == 1
    assert '"status": "pending"' in capsys.readouterr().out


def test_script_imports_original_capture_and_writes_pending_report(tmp_path):
    manifest = bundle(tmp_path, [capture(tmp_path)])
    output = tmp_path / "report.json"
    script = Path(__file__).resolve().parents[2] / "scripts" / "performance_evidence_gate.py"
    completed = subprocess.run(
        [sys.executable, str(script), str(manifest), "--output", str(output), "--strict"],
        check=False,
        text=True,
        capture_output=True,
        timeout=20,
    )
    assert completed.returncode == 1
    result = json.loads(output.read_text())
    assert result == json.loads(completed.stdout)
    assert result["buckets"][0]["boundaries"]["audio_audible"]["p95_ms"] == 150
    assert result["status"] == "pending"
