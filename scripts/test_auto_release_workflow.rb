# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

# Regression checks for the automatic release tag and GitHub release.
class AutoReleaseWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/auto-release.yml", __dir__)

  def setup
    @text = File.read(WORKFLOW)
    @workflow = YAML.safe_load(@text, aliases: true)
    @triggers = @workflow.fetch(true) { @workflow.fetch("on") }
    @steps = @workflow.fetch("jobs").fetch("auto-release").fetch("steps")
  end

  def step(name)
    @steps.find { |candidate| candidate["name"] == name } || flunk("missing step #{name.inspect}")
  end

  def test_runs_after_post_merge_validation_and_stays_dispatchable
    assert_equal ["Post-merge validation"], @triggers.fetch("workflow_run").fetch("workflows")
    assert_equal ["completed"], @triggers.fetch("workflow_run").fetch("types")
    assert @triggers.key?("workflow_dispatch"), "a manual run must stay possible"
  end

  def test_only_a_successful_validation_of_master_in_this_repository_releases
    condition = @workflow.fetch("jobs").fetch("auto-release").fetch("if")
    assert_includes condition, "github.event.workflow_run.conclusion == 'success'"
    assert_includes condition, "github.event.workflow_run.head_branch == 'master'"
    assert_includes condition, "github.event.workflow_run.head_repository.full_name == github.repository"
    assert_includes condition, "github.event_name == 'workflow_dispatch'"
  end

  def test_the_released_commit_is_the_validated_latest_master_commit
    validated = step("Require validated current merge")
    assert_includes validated.fetch("env").fetch("SOURCE_REF"), "github.event.workflow_run.head_sha"
    assert_includes validated.fetch("run"), "--latest"
    assert_equal "${{ steps.validated.outputs.sha }}", step("Checkout").fetch("with").fetch("ref")
    revalidated = step("Revalidate immediately before creating a release tag")
    assert_includes revalidated.fetch("run"), "--latest"
  end

  def test_publishes_a_github_release_with_notes_and_no_artifacts
    publish = step("Create release tag and GitHub release")
    run = publish.fetch("run")
    assert_includes run, "gh release create"
    assert_includes run, '--target "$VALIDATED_SHA"'
    assert_includes run, "--generate-notes"
    assert_includes run, '--notes-start-tag "$LAST_TAG"'
    refute_match(/release-desktop|gh workflow run|actions\/upload-artifact/, @text.sub(/^#.*$/, ""),
                 "artifact builds stay a separate, manual release-desktop run")
  end

  def test_an_existing_tag_must_already_identify_the_validated_commit
    run = step("Create release tag and GitHub release").fetch("run")
    assert_includes run, "refs/tags/${VERSION_TAG}^{commit}"
    assert_includes run, "exit 66"
  end

  def test_publication_is_serialized_and_never_cancelled
    concurrency = @workflow.fetch("concurrency")
    assert_equal false, concurrency.fetch("cancel-in-progress")
    assert_equal "auto-release", concurrency.fetch("group")
  end

  def test_permissions_allow_publishing_but_not_dispatching_workflows
    permissions = @workflow.fetch("permissions")
    assert_equal "write", permissions.fetch("contents")
    refute permissions.key?("actions"), "no workflow dispatch is needed"
  end

  def test_still_requires_one_committed_version_with_a_changelog_entry
    run = step("Validate shared app version").fetch("run")
    assert_includes run, "ruby_app/rails_gateway/VERSION"
    assert_includes run, 'changelog.include?("## [#{product_version}]")'
  end

  def test_a_version_not_newer_than_the_last_tag_publishes_nothing
    release = step("Create release tag and GitHub release")
    assert_equal "steps.bump.outputs.skip != 'true'", release.fetch("if")
    bump = step("Determine next version").fetch("run")
    assert_includes bump, "skip=true"
    assert_includes bump, "is not newer than"
  end
end
