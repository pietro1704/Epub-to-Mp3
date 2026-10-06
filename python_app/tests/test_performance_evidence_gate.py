"""CLI and legacy-summary rejection checks for the evidence importer."""

import json
import subprocess
import sys
from pathlib import Path

import pytest

from scripts import performance_evidence_gate as gate


def test_legacy_boolean_integrity_is_not_release_evidence(tmp_path):
    path = tmp_path / "legacy.json"
    path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "samples": [],
                "conversion_integrity": {"cli": True, "server": True},
            }
        )
    )
    with pytest.raises(gate.EvidenceError, match="schema_version"):
        gate.load_evidence(path)


def test_unknown_manifest_fields_are_rejected_without_echoing_private_data(tmp_path, capsys):
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps({"schema_version": 2, "captures": [], "title": "PRIVATE BOOK"}))
    assert gate.main([str(path)]) == 2
    assert "PRIVATE BOOK" not in capsys.readouterr().err


def test_duplicate_json_fields_are_rejected(tmp_path):
    path = tmp_path / "manifest.json"
    path.write_text('{"schema_version":2,"captures":[],"captures":[]}')
    with pytest.raises(gate.EvidenceError, match="duplicate"):
        gate.load_evidence(path)


@pytest.mark.parametrize("budget", [float("inf"), float("nan"), True, 0, -1])
def test_invalid_budgets_cannot_suppress_failures(budget):
    with pytest.raises(gate.EvidenceError):
        gate.evaluate([], warm_budget_ms=budget)


def test_percentile_uses_interpolation_and_rejects_empty_values():
    assert gate.percentile(range(20), 0.95) == pytest.approx(18.05)
    with pytest.raises(gate.EvidenceError):
        gate.percentile([], 0.95)


def test_script_entry_point_emits_pending_and_strict_failure(tmp_path):
    path = tmp_path / "empty.json"
    path.write_text('{"schema_version":2,"captures":[]}')
    script = Path(__file__).resolve().parents[2] / "scripts" / "performance_evidence_gate.py"
    result = subprocess.run(
        [sys.executable, str(script), str(path), "--strict"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    payload = json.loads(result.stdout)
    assert payload["status"] == "pending"
    assert len(payload["missing"]) == 18
