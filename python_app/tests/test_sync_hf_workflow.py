"""Regression checks for selective Hugging Face synchronization."""

from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[2] / ".github" / "workflows" / "sync-hf.yml"
REMEDIATION_WORKFLOW = (
    Path(__file__).resolve().parents[2] / ".github" / "workflows" / "code-scanning-remediation.yml"
)


def test_hf_sync_only_tracks_space_runtime_paths() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    assert "Detect Space-relevant changes" in workflow
    assert "python_app/" in workflow
    assert "web/" in workflow
    assert "needs.changes.outputs.should_sync == 'true'" in workflow
    assert "workflow_dispatch" in workflow


def test_hf_sync_checks_out_only_the_trusted_master_branch() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    assert workflow.count("ref: master") == 2
    assert "github.event.workflow_run.head_sha" not in workflow
    assert "issues: write" not in workflow


def test_code_scanning_remediation_repairs_existing_tracking_issues() -> None:
    workflow = REMEDIATION_WORKFLOW.read_text(encoding="utf-8")

    assert "Determine remediation status" in workflow
    assert "tracking_exists" in workflow
    assert "steps.remediation.outputs.skip != 'true'" in workflow
    assert "steps.dedupe.outputs.skip" not in workflow
