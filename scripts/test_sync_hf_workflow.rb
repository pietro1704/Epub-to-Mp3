# frozen_string_literal: true

require "minitest/autorun"

# Regression checks for validated Hugging Face synchronization.
class SyncHfWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/sync-hf.yml", __dir__)

  def setup
    @workflow = File.read(WORKFLOW)
  end

  def test_hf_sync_snapshots_only_the_validated_revision
    assert_includes @workflow, "mise run hf:snapshot --"
    assert_includes @workflow, "scripts/hf_push.sh"
    assert_includes @workflow, "persist-credentials: false"
    refute_includes @workflow, '--exclude "python_app"'
    assert_includes @workflow, "needs: gate"
    assert_includes @workflow, "ref: ${{ needs.gate.outputs.sha }}"
    assert_includes @workflow, 'workflows: ["Post-merge validation"]'
    assert_includes @workflow, "workflow_dispatch"
  end

  def test_hf_sync_checks_out_the_trusted_workflow_revision
    assert_includes @workflow, "ref: master"
    assert_includes @workflow, "scripts/validated_merge.mjs"
    assert_includes @workflow, '--ref "$SOURCE_REF" --latest'
    assert_includes @workflow, '--ref "$VALIDATED_SHA" --latest'
    validated = @workflow.index('--ref "$VALIDATED_SHA" --latest')
    push = @workflow.index("bash scripts/hf_push.sh")
    refute_nil push
    assert_operator validated, :<, push
    refute_includes @workflow, "issues: write"
  end
end
