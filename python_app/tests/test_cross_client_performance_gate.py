"""Tests for the isolated cross-client evidence gate."""

import json
import subprocess
import sys
from pathlib import Path
from uuid import UUID

import pytest

from scripts import cross_client_performance_gate as gate

HEX = "a" * 64
REVISION = "b" * 64
CLIENTS = gate.CLIENTS
CORPORA = gate.CORPORA


def _sample(client, corpus, cache, index, *, audible=100):
    return {
        "client": client,
        "corpus": corpus,
        "cache_state": cache,
        "run_id": str(UUID(int=index + 1)),
        "revision": REVISION,
        "runner": f"runner-{client}",
        "execution_environment": "physical_device" if client == "apple" else "profile_runner",
        "resource_policy": "normal",
        "corpus_sha256": HEX,
        "corpus_size_bytes": 1000,
        "boundaries_ms": {
            "client": 50,
            "streaming_backend": 70,
            "queue": 80,
            "audible": audible,
        },
        "integrity": {"conversion": True, "output": True},
    }


def _manifest(samples=None, *, unavailable=()):
    unavailable = set(unavailable)
    return {
        "schema_version": 1,
        "collectors": {
            client: {"available": client not in unavailable} for client in CLIENTS
        },
        "corpora": {
            corpus: {"available": corpus not in unavailable} for corpus in CORPORA
        },
        "samples": samples or [],
    }


def _complete_samples(**kwargs):
    samples = []
    index = 0
    for client in CLIENTS:
        for corpus in CORPORA:
            for cache in gate.CACHE_STATES:
                for _ in range(20):
                    samples.append(_sample(client, corpus, cache, index, **kwargs))
                    index += 1
    return samples


def test_empty_matrix_is_pending_for_every_cross_client_bucket():
    report = gate.evaluate([], collectors={c: {"available": True} for c in CLIENTS}, corpora={c: {"available": True} for c in CORPORA})
    assert report["status"] == "pending"
    assert len(report["missing"]) == 18
    assert {"insufficient_samples"} == set(report["missing"][0]["pending_reasons"])


def test_complete_twenty_cold_and_warm_matrix_passes():
    samples, metadata = gate.load_manifest_from_payload(_manifest(_complete_samples()))
    report = gate.evaluate(samples, **metadata)
    assert report["status"] == "passed"
    assert len(report["buckets"]) == 18
    assert all(bucket["sample_count"] == 20 for bucket in report["buckets"])
    assert report["buckets"][0]["boundaries"]["audible"]["p95_ms"] == 100


def test_unavailable_collector_stays_pending_instead_of_passing():
    samples, _ = gate.load_manifest_from_payload(_manifest(_complete_samples()))
    report = gate.evaluate(
        samples,
        collectors={client: {"available": client != "flutter"} for client in CLIENTS},
    )
    assert report["status"] == "pending"
    flutter = [bucket for bucket in report["missing"] if bucket["client"] == "flutter"]
    assert len(flutter) == 6
    assert all("collector_unavailable" in bucket["pending_reasons"] for bucket in flutter)


def test_unavailable_corpus_stays_pending_without_substitution():
    samples, _ = gate.load_manifest_from_payload(_manifest(_complete_samples()))
    report = gate.evaluate(
        samples,
        corpora={corpus: {"available": corpus != "epub"} for corpus in CORPORA},
    )
    assert report["status"] == "pending"
    assert len([item for item in report["missing"] if item["corpus"] == "epub"]) == 6


def test_cross_client_boundary_schema_is_required():
    sample = _sample("web", "epub", "cold", 0)
    del sample["boundaries_ms"]["queue"]
    with pytest.raises(gate.EvidenceError, match="boundary schema"):
        gate.load_manifest_from_payload(_manifest([sample]))


def test_budget_failure_keeps_optimization_boundary():
    samples, metadata = gate.load_manifest_from_payload(_manifest(_complete_samples(audible=1001)))
    report = gate.evaluate(samples, **metadata)
    assert report["status"] == "failed"
    assert len(report["budget_exceeded"]) == 18
    assert all(item["boundaries"]["audible"]["p95_ms"] == 1001 for item in report["budget_exceeded"])
    assert report["optimization_queue"][0]["cache_state"] in gate.CACHE_STATES


def test_failed_output_integrity_cannot_pass_a_complete_cohort():
    raw = _complete_samples()
    raw[0]["integrity"]["output"] = False
    samples, metadata = gate.load_manifest_from_payload(_manifest(raw))
    report = gate.evaluate(samples, **metadata)
    assert report["status"] == "failed"
    assert report["budget_exceeded"][0]["integrity_failure"] is True


def test_reused_run_id_and_conflicting_corpus_metadata_are_rejected():
    samples = [_sample("apple", "epub", "cold", 0), _sample("web", "epub", "cold", 0)]
    with pytest.raises(gate.EvidenceError, match="run_id"):
        gate.evaluate(tuple(gate._sample(item, {c: {"available": True} for c in CORPORA}) for item in samples))
    second = _sample("web", "epub", "cold", 1)
    second["corpus_sha256"] = "c" * 64
    with pytest.raises(gate.EvidenceError, match="metadata"):
        gate.evaluate(tuple(gate._sample(item, {c: {"available": True} for c in CORPORA}) for item in [_sample("apple", "epub", "cold", 0), second]))


def test_cli_reports_pending_and_strict_returns_failure(tmp_path):
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(_manifest()), encoding="utf-8")
    script = Path(__file__).resolve().parents[2] / "scripts" / "cross_client_performance_gate.py"
    result = subprocess.run([sys.executable, str(script), str(path), "--strict"], capture_output=True, text=True, check=False)
    assert result.returncode == 1
    assert json.loads(result.stdout)["status"] == "pending"


def test_duplicate_manifest_keys_are_rejected(tmp_path):
    path = tmp_path / "manifest.json"
    path.write_text('{"schema_version":1,"collectors":{},"collectors":{}}', encoding="utf-8")
    with pytest.raises(gate.EvidenceError, match="duplicate"):
        gate.load_manifest(path)
