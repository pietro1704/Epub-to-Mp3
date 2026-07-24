"""Regression checks for selective Hugging Face synchronization."""

from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[2] / ".github" / "workflows" / "sync-hf.yml"


def test_hf_sync_only_tracks_space_runtime_paths() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    assert "Detect Space-relevant changes" in workflow
    assert "python_app/" in workflow
    assert "web/" in workflow
    assert "needs.changes.outputs.should_sync == 'true'" in workflow
    assert "workflow_dispatch" in workflow
