"""Regression coverage for durable CodeQL analysis uploads."""

from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[2] / ".github" / "workflows" / "codeql.yml"


def test_codeql_runs_are_not_cancelled_by_newer_pushes() -> None:
    """Cancelled CodeQL runs upload failed SARIF and poison configuration status."""
    workflow = WORKFLOW.read_text(encoding="utf-8")

    assert "group: codeql-${{ github.workflow }}-${{ github.ref }}" in workflow
    assert "cancel-in-progress: false" in workflow
