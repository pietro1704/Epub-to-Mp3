# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require_relative "next_release_version"

class NextReleaseVersionTest < Minitest::Test
  def plan(subjects, last: "v0.5.8", committed: "0.5.8", bodies: [])
    NextReleaseVersion.plan(last_tag: last, committed_version: committed, subjects: subjects, bodies: bodies)
  end

  def test_only_chores_docs_ci_tests_and_refactors_do_not_release
    result = plan(["chore: tidy", "docs: x", "ci: y", "test: z", "refactor(a): w", "style: v", "build: u"])
    assert_equal "none", result.bump
    assert_nil result.version
  end

  def test_a_fix_or_perf_makes_a_patch_release
    assert_equal "0.5.9", plan(["chore: a", "fix(reader): b (#1)"]).version
    assert_equal "0.5.9", plan(["perf: faster"]).version
  end

  def test_a_feature_makes_a_minor_release_and_wins_over_fixes
    result = plan(["fix: a", "feat(web): b", "fix: c"])
    assert_equal "minor", result.bump
    assert_equal "0.6.0", result.version
  end

  def test_a_breaking_change_is_a_minor_release_while_the_major_version_is_zero
    assert_equal "0.6.0", plan(["refactor!: drop it"]).version
    assert_equal "0.6.0", plan(["chore(web)!: cut over"]).version
    assert_equal "0.6.0", plan(["fix: a"], bodies: ["BREAKING CHANGE: nope"]).version
  end

  def test_a_breaking_change_is_a_major_release_from_one_point_zero
    result = plan(["feat!: new api"], last: "v1.4.2", committed: "1.4.2")
    assert_equal "major", result.bump
    assert_equal "2.0.0", result.version
  end

  def test_feature_and_fix_follow_semver_from_one_point_zero
    assert_equal "1.5.0", plan(["feat: a"], last: "v1.4.2", committed: "1.4.2").version
    assert_equal "1.4.3", plan(["fix: a"], last: "v1.4.2", committed: "1.4.2").version
  end

  def test_non_conventional_subjects_are_ignored
    assert_equal "none", plan(["Flutter parity 1/6: reference and device acceptance (#1131)", "Merge branch x"]).bump
  end

  def test_a_committed_version_newer_than_the_last_tag_is_left_to_the_release_workflow
    result = plan(["feat: a"], committed: "0.6.0")
    assert_equal "committed", result.bump
    assert_equal "0.6.0", result.version
  end

  def test_a_committed_version_above_the_computed_one_wins
    assert_equal "0.7.0", plan(["fix: a"], committed: "0.7.0").version
  end

  def test_without_a_previous_tag_any_release_is_the_committed_version
    result = plan(["feat: a"], last: "", committed: "0.1.0")
    assert_equal "0.1.0", result.version
  end

  def test_squash_merge_bodies_prefix_inner_commit_lines_with_a_bullet
    squash = "* fix: inner\n\n* BREAKING CHANGE: dropped the old api"
    assert_equal "0.6.0", plan(["chore: squash title (#9)"], bodies: [squash]).version
    assert_equal "0.6.0", plan(["chore: squash title (#9)"], bodies: ["- BREAKING-CHANGE: x"]).version
  end

  def test_a_breaking_inner_commit_in_a_squash_body_counts
    assert_equal "0.6.0", plan(["chore: squash title (#9)"], bodies: ["* feat(api)!: new contract"]).version
  end

  def test_only_the_pull_request_title_counts_for_feat_and_fix
    assert_equal "none", plan(["chore: squash title (#9)"], bodies: ["* feat: inner feature\n* fix: inner fix"]).bump
  end

  def test_breaking_text_in_the_middle_of_a_line_is_not_a_breaking_change
    assert_equal "none", plan(["chore: a"], bodies: ["explains why BREAKING CHANGE: is not used here"]).bump
  end

  def test_the_command_line_reads_subjects_and_prints_outputs
    input = "fix: a\n\0feat: b\n\0"
    out, status = Open3.capture2("ruby", File.expand_path("next_release_version.rb", __dir__),
                                 "--last-tag", "v0.5.8", "--committed", "0.5.8", stdin_data: input)
    assert status.success?
    assert_includes out, "bump=minor"
    assert_includes out, "version=0.6.0"
  end
end
