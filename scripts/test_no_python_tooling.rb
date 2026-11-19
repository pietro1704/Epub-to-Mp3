# frozen_string_literal: true

require "minitest/autorun"
require "open3"

# D30: host tooling is Ruby and the repository carries no first-party Python.
# Vendored third-party sources under native/vendor keep their upstream scripts.
class NoPythonToolingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  # Lowercase command words; prose such as "no Python runtime" and the
  # guard_no_python_production.sh / no-python-production names stay allowed.
  COMMAND = /(?<![\w:-])(?:python3?|pytest|ruff|pip3?)(?![\w-])/

  def tracked(*patterns)
    output, status = Open3.capture2("git", "-C", ROOT, "ls-files", "-z", "--", *patterns)
    assert status.success?, "git ls-files failed"
    output.split("\0")
  end

  def test_no_first_party_python_sources_are_tracked
    python = tracked("*.py", "*.pyi").reject { |path| path.start_with?("native/vendor/") }
    assert_empty python
    assert_empty tracked("pyproject.toml", "requirements*.txt", "setup.py", "setup.cfg", "tox.ini")
  end

  def test_mise_declares_no_python_tool_or_python_invocations
    mise = File.read(File.join(ROOT, "mise.toml"))
    tools = mise[/^\[tools\]\n(.*?)^\[/m, 1]
    refute_nil tools
    refute_match(/^python\s*=/, tools)
    refute_match(COMMAND, mise)
  end

  def test_workflows_and_hooks_do_not_run_python
    files = Dir[File.join(ROOT, ".github/workflows/*.yml")] + [File.join(ROOT, ".pre-commit-config.yaml")]
    files.each do |path|
      refute_match(COMMAND, File.read(path), path)
    end
  end
end
