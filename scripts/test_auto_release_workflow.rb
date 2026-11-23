# frozen_string_literal: true

require "minitest/autorun"
require "open3"
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

  def test_superseded_event_cannot_start_release_preparation
    assert_equal "${{ inputs.validation_run != '' }}", step("Require validated current merge").fetch("env").fetch("SKIP_SUPERSEDED")
    assert_equal "steps.validated.outputs.sha != ''", step("Checkout").fetch("if")
    assert_equal "steps.validated.outputs.sha != ''", step("Validate shared app version").fetch("if")
    assert_equal "steps.validated.outputs.sha != ''", step("Determine next version").fetch("if")
  end

  def test_is_dispatched_by_post_merge_validation_and_has_no_workflow_run_trigger
    refute @triggers.key?("workflow_run"), "Post-merge validation dispatches the publisher directly"
    assert @triggers.key?("workflow_dispatch"), "a manual run must stay possible"
    assert_equal false, @triggers.fetch("workflow_dispatch").fetch("inputs").fetch("validation_run").fetch("required")
  end

  def test_only_a_successful_validation_of_master_in_this_repository_releases
    condition = @workflow.fetch("jobs").fetch("auto-release").fetch("if")
    assert_equal "github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/master'", condition
  end

  def test_the_released_commit_is_the_validated_latest_master_commit
    validated = step("Require validated current merge")
    assert_equal "${{ github.sha }}", validated.fetch("env").fetch("SOURCE_REF")
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
    refute_match(/actions\/upload-artifact/, @text, "artifacts are built by release-desktop, not here")
  end

  def test_missing_official_android_signing_reference_blocks_release_creation
    gate = step("Require the official Android signing reference")
    assert_equal "steps.bump.outputs.skip == 'false'", gate.fetch("if")
    assert_operator @steps.index(gate), :<, @steps.index(step("Create release tag and GitHub release"))
    _, error, status = Open3.capture3({ "ANDROID_SIGNING_AVAILABLE" => "false" }, "bash", "-c", gate.fetch("run"))
    refute status.success?, error
    _, error, status = Open3.capture3({ "ANDROID_SIGNING_AVAILABLE" => "true" }, "bash", "-c", gate.fetch("run"))
    assert status.success?, error
  end

  # Owner decision 2026-11-20: every new release builds its packages. The tag is
  # created with GITHUB_TOKEN, which starts no workflow, so Release Desktop is
  # dispatched explicitly, for exactly the new tag, after the release exists.
  def test_a_new_release_starts_the_package_builds_for_its_tag
    start = step("Start the release packages")
    assert_equal "steps.bump.outputs.skip == 'false'", start.fetch("if")
    assert_equal "${{ steps.bump.outputs.tag }}", start.fetch("env").fetch("VERSION_TAG")
    assert_equal 'gh workflow run release-desktop.yml --repo "$GITHUB_REPOSITORY" --ref master -f tag="$VERSION_TAG"',
                 start.fetch("run").strip
    assert_operator @steps.index(step("Create release tag and GitHub release")), :<, @steps.index(start)
    assert_equal "write", @workflow.fetch("permissions").fetch("actions")
    assert_equal 1, @text.scan("gh workflow run").size, "nothing else is dispatched"
  end

  def test_a_manual_run_can_only_use_the_workflow_definition_of_master
    # The job holds a contents: write token, so a feature branch must not be able to run its own copy.
    refute_match(/github\.event_name == 'workflow_dispatch' \|\|/, @workflow.fetch("jobs").fetch("auto-release").fetch("if"))
  end

  def test_a_tag_without_a_release_still_gets_one
    bump = step("Determine next version").fetch("run")
    assert_includes bump, 'gh release view "v${NEW}"'
    refute_match(/Tag v\$\{NEW\} already exists; skipping/, bump)
  end

  def test_comments_name_the_real_version_files
    assert_includes @text, "ruby_app/rails_gateway/VERSION"
    refute_match(/raises Cargo\.toml, VERSION and CHANGELOG/, @text)
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

  def test_permissions_allow_publishing_and_starting_only_the_release_packages
    permissions = @workflow.fetch("permissions")
    assert_equal "write", permissions.fetch("contents")
    assert_equal({ "contents" => "write", "pull-requests" => "read", "actions" => "write" }, permissions)
  end

  def test_still_requires_one_committed_version_with_a_changelog_entry
    run = step("Validate shared app version").fetch("run")
    assert_includes run, "ruby_app/rails_gateway/VERSION"
    assert_includes run, 'changelog.include?("## [#{product_version}]")'
  end

  def test_a_version_not_newer_than_the_last_tag_publishes_nothing
    release = step("Create release tag and GitHub release")
    assert_equal "steps.bump.outputs.skip == 'false'", release.fetch("if")
    bump = step("Determine next version").fetch("run")
    assert_includes bump, "skip=true"
    assert_includes bump, "is not newer than"
  end
end
