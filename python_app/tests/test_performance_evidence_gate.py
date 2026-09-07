from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parents[2] / "scripts" / "performance_evidence_gate.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("performance_evidence_gate", _SCRIPT_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


GATE = _load_module()
_SHA = "a" * 64


def _sample(
    *,
    client: str = "apple",
    corpus: str = "epub",
    cache_state: str = "cold",
    reader_usable: float = 100,
    audio_audible: float = 150,
) -> dict[str, object]:
    return {
        "client": client,
        "runner": "iPhone 16e" if client == "apple" else "Chromium",
        "execution_environment": "physical_device" if client == "apple" else "browser_profile",
        "corpus": {"kind": corpus, "sha256": _SHA, "size_bytes": 1000, "page_count": 10},
        "cache_state": cache_state,
        "resource_policy": "normal",
        "boundaries_ms": {"reader_usable": reader_usable, "audio_audible": audio_audible},
    }


def _write_bundle(
    path: Path,
    samples: list[dict[str, object]],
    conversion_integrity: dict[str, bool] | None = None,
) -> None:
    path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "samples": samples,
                "conversion_integrity": {"cli": True, "server": True}
                if conversion_integrity is None
                else conversion_integrity,
            }
        ),
        encoding="utf-8",
    )


def test_missing_evidence_remains_pending(tmp_path: Path) -> None:
    bundle = tmp_path / "evidence.json"
    _write_bundle(bundle, [_sample()])

    evidence = GATE.load_evidence(bundle)
    report = GATE.evaluate(
        evidence.samples,
        clients=("apple",),
        corpora=("epub",),
        required_samples=20,
        conversion_integrity=evidence.conversion_integrity,
    )

    assert report["status"] == "pending"
    assert report["missing"] == [
        {"client": "apple", "corpus": "epub", "cache_state": "cold", "sample_count": 1, "required_sample_count": 20},
        {"client": "apple", "corpus": "epub", "cache_state": "relaunch_warm", "sample_count": 0, "required_sample_count": 20},
    ]


def test_complete_evidence_reports_p50_p95_and_budget_failure(tmp_path: Path) -> None:
    bundle = tmp_path / "evidence.json"
    samples = [
        _sample(reader_usable=100 + index, audio_audible=300 + index)
        for index in range(20)
    ] + [
        _sample(cache_state="relaunch_warm", reader_usable=250, audio_audible=150)
        for _ in range(20)
    ]
    _write_bundle(bundle, samples)

    evidence = GATE.load_evidence(bundle)
    report = GATE.evaluate(
        evidence.samples,
        clients=("apple",),
        corpora=("epub",),
        required_samples=20,
        conversion_integrity=evidence.conversion_integrity,
    )

    assert report["status"] == "failed"
    cold, warm = report["buckets"]
    assert cold["boundaries"]["reader_usable"] == {"p50_ms": 109.5, "p95_ms": 118.05}
    assert cold["within_budget"] is True
    assert warm["within_budget"] is False
    assert report["optimization_queue"] == [
        {
            "client": "apple",
            "corpus": "epub",
            "cache_state": "relaunch_warm",
            "boundary": "reader_usable_or_audio_audible",
            "p95_ms": 250.0,
            "budget_ms": 200,
        }
    ]


def test_complete_in_budget_evidence_passes(tmp_path: Path) -> None:
    bundle = tmp_path / "evidence.json"
    samples = [_sample() for _ in range(20)] + [
        _sample(cache_state="relaunch_warm", reader_usable=120, audio_audible=170)
        for _ in range(20)
    ]
    _write_bundle(bundle, samples)

    evidence = GATE.load_evidence(bundle)
    report = GATE.evaluate(
        evidence.samples,
        clients=("apple",),
        corpora=("epub",),
        required_samples=20,
        conversion_integrity=evidence.conversion_integrity,
    )

    assert report["status"] == "passed"
    assert report["missing"] == []
    assert report["optimization_queue"] == []


def test_rejects_simulator_as_apple_evidence(tmp_path: Path) -> None:
    bundle = tmp_path / "evidence.json"
    sample = _sample()
    sample["execution_environment"] = "simulator"
    _write_bundle(bundle, [sample])

    with pytest.raises(GATE.EvidenceError, match="physical device"):
        GATE.load_evidence(bundle)


def test_accepts_compatible_apple_ci_runner(tmp_path: Path) -> None:
    bundle = tmp_path / "evidence.json"
    sample = _sample()
    sample["execution_environment"] = "apple_ci"
    _write_bundle(bundle, [sample])

    assert GATE.load_evidence(bundle).samples[0].execution_environment == "apple_ci"


def test_missing_conversion_integrity_remains_pending(tmp_path: Path) -> None:
    bundle = tmp_path / "evidence.json"
    samples = [_sample() for _ in range(20)] + [_sample(cache_state="relaunch_warm") for _ in range(20)]
    _write_bundle(bundle, samples, conversion_integrity={})

    evidence = GATE.load_evidence(bundle)
    report = GATE.evaluate(
        evidence.samples,
        clients=("apple",),
        corpora=("epub",),
        required_samples=20,
        conversion_integrity=evidence.conversion_integrity,
    )

    assert report["status"] == "pending"
    assert report["missing_conversion_integrity"] == ["cli", "server"]


def test_strict_cli_fails_for_pending_evidence(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    bundle = tmp_path / "evidence.json"
    _write_bundle(bundle, [_sample()])

    exit_code = GATE.main([
        str(bundle),
        "--clients",
        "apple",
        "--corpora",
        "epub",
        "--samples",
        "20",
        "--strict",
    ])

    assert exit_code == 1
    assert '"status": "pending"' in capsys.readouterr().out
