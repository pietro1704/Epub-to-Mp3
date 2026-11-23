# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

# Regression checks for the workflow that opens the version-bump pull request.
class ReleasePrWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/release-pr.yml", __dir__)

  def setup
    @text = File.read(WORKFLOW)
    @workflow = YAML.safe_load(@text, aliases: true)
    @triggers = @workflow.fetch(true) { @workflow.fetch("on") }
    @job = @workflow.fetch("jobs").fetch("release-pr")
    @steps = @job.fetch("steps")
  end

  def step(name)
    @steps.find { |candidate| candidate["name"] == name } || flunk("missing step #{name.inspect}")
  end

  def test_superseded_event_cannot_start_release_preparation
    assert_equal "${{ inputs.validation_run != '' }}", step("Require validated current merge").fetch("env").fetch("SKIP_SUPERSEDED")
    assert_equal "steps.validated.outputs.sha != ''", step("Checkout").fetch("if")
    assert_equal "steps.validated.outputs.sha != ''", step("Plan the next version").fetch("if")
  end

  def test_is_dispatched_by_post_merge_validation_like_auto_release
    refute @triggers.key?("workflow_run"), "Post-merge validation dispatches the publisher directly"
    assert_equal "github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/master'", @job.fetch("if")
  end

  def test_works_from_the_validated_latest_master_commit_with_trusted_helpers
    assert_includes step("Snapshot trusted helpers").fetch("run"), "publication-policy/scripts/next_release_version.rb"
    assert_includes step("Require validated current merge").fetch("run"), "--latest"
    assert_equal "${{ steps.validated.outputs.sha }}", step("Checkout").fetch("with").fetch("ref")
    assert_equal false, step("Checkout").fetch("with").fetch("persist-credentials")
  end

  def test_never_has_write_access_to_the_repository_contents_through_the_default_token
    permissions = @workflow.fetch("permissions")
    assert_equal "read", permissions.fetch("contents")
    refute_includes permissions.values, "write"
  end

  def test_without_the_release_token_it_only_reports_a_notice
    run = step("Plan the next version").fetch("run")
    assert_includes run, 'if [[ -z "${RELEASE_PR_TOKEN:-}" ]]'
    assert_includes run, "::notice::RELEASE_PR_TOKEN is not configured"
    assert_equal "${{ secrets.RELEASE_PR_TOKEN }}", step("Plan the next version").fetch("env").fetch("RELEASE_PR_TOKEN")
  end

  def test_releases_nothing_when_there_is_nothing_to_release_or_a_version_is_already_committed
    run = step("Plan the next version").fetch("run")
    assert_includes run, "none) emit"
    assert_includes run, "committed) emit"
    assert_includes run, "next_release_version.rb"
  end

  def test_an_open_release_pull_request_blocks_only_an_equal_or_newer_version
    run = step("Plan the next version").fetch("run")
    assert_includes run, "gh pr list --state open --limit 100"
    assert_includes run, 'startswith("release/v")'
    assert_includes run, "already open for ${OPEN_VERSION}"
    assert_includes run, "supersede="
  end

  def test_a_stale_lower_release_pull_request_is_closed_and_its_branch_deleted
    push = step("Push the branch and open the pull request")
    run = push.fetch("run")
    assert_includes run, "gh pr close"
    assert_includes run, "--delete-branch"
    assert_equal "${{ steps.plan.outputs.supersede }}", push.fetch("env").fetch("SUPERSEDE")
  end

  def test_a_leftover_remote_branch_for_the_version_is_removed_before_pushing
    run = step("Push the branch and open the pull request").fetch("run")
    assert_includes run, 'git/refs/heads/release/v${VERSION}'
    assert_operator run.index("-X DELETE"), :<, run.index("git -c credential.helper= ")
  end

  def test_comments_name_the_real_version_files
    assert_includes @text, "ruby_app/rails_gateway/VERSION"
    refute_match(/Cargo\.toml, Cargo\.lock, VERSION, CHANGELOG/, @text)
  end

  def test_the_tag_is_dropped_and_only_the_branch_is_pushed
    assert_includes step("Raise the version and the changelog").fetch("run"), 'git tag -d "v${VERSION}"'
    push = step("Push the branch and open the pull request").fetch("run")
    assert_includes push, 'HEAD:refs/heads/release/v${VERSION}'
    refute_match(/refs\/tags|push --tags|--follow-tags/, push)
  end

  def test_the_token_is_used_only_by_the_pull_request_step_and_never_put_in_a_url
    holders = @steps.select { |candidate| candidate.to_s.include?("secrets.RELEASE_PR_TOKEN") }.map { |candidate| candidate["name"] }
    assert_equal ["Plan the next version", "Push the branch and open the pull request"], holders
    refute_match(/x-access-token|https:\/\/[^ ]*@github\.com/, @text)
  end

  def test_the_changelog_entry_is_required_before_committing
    run = step("Commit the release").fetch("run")
    assert_includes run, 'grep -q "## \[${VERSION}\]" CHANGELOG.md'
    assert_includes run, 'chore(release): v${VERSION}'
  end

  def test_the_workflow_never_merges_a_pull_request_itself
    # Only the trusted merge helper may merge; this workflow just opens the release pull request.
    refute_match(/\bgh\s+pr\s+merge\b|\bpulls\.merge\s*\(|\/pulls\/[^\s]+\/merge\b|--auto/, @text)
  end

  def test_publication_is_serialized
    assert_equal "release-pr", @workflow.fetch("concurrency").fetch("group")
    assert_equal false, @workflow.fetch("concurrency").fetch("cancel-in-progress")
  end
end
