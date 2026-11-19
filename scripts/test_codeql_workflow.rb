# frozen_string_literal: true

require "minitest/autorun"

# Cancelled CodeQL runs upload failed SARIF and poison configuration status.
class CodeqlWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/codeql.yml", __dir__)

  def test_codeql_runs_are_not_cancelled_by_newer_pushes
    workflow = File.read(WORKFLOW)

    assert_includes workflow, "group: codeql-${{ github.workflow }}-${{ github.ref }}"
    assert_includes workflow, "cancel-in-progress: false"
  end
end
