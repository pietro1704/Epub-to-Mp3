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
    assert_includes @workflow, "if: needs.gate.outputs.sha != ''"
    assert_includes @workflow, "SKIP_SUPERSEDED: ${{ github.event_name == 'workflow_run' }}"
    assert_includes @workflow, "ref: ${{ needs.gate.outputs.sha }}"
    assert_includes @workflow, 'workflows: ["Post-merge validation"]'
    assert_includes @workflow, "workflow_dispatch"
  end

  def test_hf_sync_checks_out_the_trusted_workflow_revision
    assert_includes @workflow, "ref: master"
    assert_includes @workflow, "scripts/validated_merge.mjs"
    publication = ' --required-job "Publication surfaces validated"'
    assert_includes @workflow, "--ref \"$SOURCE_REF\" --latest#{publication}"
    assert_includes @workflow, "--ref \"$VALIDATED_SHA\" --latest#{publication}"
    validated = @workflow.index("--ref \"$VALIDATED_SHA\" --latest#{publication}")
    push = @workflow.index("bash scripts/hf_push.sh")
    refute_nil push
    assert_operator validated, :<, push
    refute_includes @workflow, "issues: write"
  end

  # A failed post-merge run reaches the gate; validated_merge.mjs then requires the
  # publication job of that exact attempt, so cancelled or skipped runs never publish.
  def test_hf_sync_gate_admits_only_completed_master_runs_for_the_publication_job_check
    require "yaml"
    gate = YAML.load_file(WORKFLOW).fetch("jobs").fetch("gate").fetch("if")
    assert_includes gate, %q{contains(fromJSON('["success","failure"]'), github.event.workflow_run.conclusion)}
    refute_match(/cancelled|skipped|neutral|timed_out/, gate)
    assert_includes gate, "github.event.workflow_run.head_branch == 'master'"
    assert_includes gate, "github.event.workflow_run.head_repository.full_name == github.repository"
  end
end
