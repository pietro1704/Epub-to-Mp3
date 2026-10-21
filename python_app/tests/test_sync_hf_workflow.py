"""Regression checks for validated Hugging Face synchronization."""

from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[2] / ".github" / "workflows" / "sync-hf.yml"
REMEDIATION_WORKFLOW = (
    Path(__file__).resolve().parents[2] / ".github" / "workflows" / "code-scanning-remediation.yml"
)


def test_hf_sync_snapshots_only_the_validated_revision() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    assert "mise run hf:snapshot --" in workflow
    assert "scripts/hf_push.sh" in workflow
    assert "persist-credentials: false" in workflow
    assert '--exclude "python_app"' not in workflow
    assert "needs: gate" in workflow
    assert "ref: ${{ needs.gate.outputs.sha }}" in workflow
    assert 'workflows: ["Post-merge validation"]' in workflow
    assert "workflow_dispatch" in workflow


def test_hf_sync_checks_out_the_trusted_workflow_revision() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    assert "ref: master" in workflow
    assert "scripts/validated_merge.mjs" in workflow
    assert '--ref "$SOURCE_REF" --latest' in workflow
    assert '--ref "$VALIDATED_SHA" --latest' in workflow
    assert workflow.index('--ref "$VALIDATED_SHA" --latest') < workflow.index("bash scripts/hf_push.sh")
    assert "issues: write" not in workflow


def test_code_scanning_remediation_repairs_existing_tracking_issues() -> None:
    workflow = REMEDIATION_WORKFLOW.read_text(encoding="utf-8")

    assert "Determine remediation status" in workflow
    assert "tracking_exists" in workflow
    assert "steps.remediation.outputs.skip != 'true'" in workflow
    assert "steps.dedupe.outputs.skip" not in workflow
