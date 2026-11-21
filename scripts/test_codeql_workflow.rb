# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

# Cancelled CodeQL runs upload failed SARIF and poison configuration status.
class CodeqlWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/codeql.yml", __dir__)

  def test_codeql_runs_are_not_cancelled_by_newer_pushes
    workflow = File.read(WORKFLOW)

    assert_includes workflow, "group: codeql-${{ github.workflow }}-${{ github.ref }}"
    assert_includes workflow, "cancel-in-progress: false"
  end

  def test_apple_cache_does_not_restore_across_sonic_source_changes
    jobs = YAML.load_file(WORKFLOW).fetch("jobs")
    cache = jobs.values.flat_map { |job| job.fetch("steps", []) }.find do |step|
      step["name"] == "Reuse compatible Rust dependencies across Apple jobs"
    end
    refute_nil cache
    settings = cache.fetch("with")
    ([settings.fetch("key")] + settings.fetch("restore-keys").lines).each do |key|
      assert_includes key, "native/vendor/espeak-rs-sys/espeak-ng/cmake/**"
      assert_includes key, "native/vendor/espeak-rs-sys/espeak-ng/src/sonic/**"
    end
  end
end
