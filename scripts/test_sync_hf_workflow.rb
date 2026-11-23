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
    assert_includes @workflow, "SKIP_SUPERSEDED: ${{ inputs.validation_run != '' }}"
    assert_includes @workflow, "ref: ${{ needs.gate.outputs.sha }}"
    refute_includes @workflow, "workflow_run"
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

  # Post-merge validation dispatches this workflow once its publication job succeeded, even
  # when unrelated platform jobs failed; validated_merge.mjs then requires the publication job
  # of that exact attempt, so cancelled or skipped runs never publish.
  def test_hf_sync_is_started_only_by_dispatch_and_keeps_the_publication_job_gate
    require "yaml"
    workflow = YAML.load_file(WORKFLOW)
    gate = workflow.fetch("jobs").fetch("gate").fetch("if")
    assert_equal "github.event_name == 'workflow_dispatch'", gate
    refute((workflow["on"] || workflow[true]).key?("workflow_run"))
    assert_includes @workflow, '--required-job "Publication surfaces validated"'
  end
end
