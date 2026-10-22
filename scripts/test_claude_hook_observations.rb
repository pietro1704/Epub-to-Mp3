# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"

# Real compatibility shells operate only on synthetic checkout records.
# These regression cases are authored, not executed by the static-only campaign.
class ClaudeHookObservationsTest < Minitest::Test
  SOURCE = File.expand_path("../.claude/hooks", __dir__)

  def setup
    @temporary = Dir.mktmpdir("legacy hooks ")
    @root = File.join(@temporary, "checkout ' literal")
    @hooks = File.join(@root, ".claude/hooks")
    FileUtils.mkdir_p([@hooks, File.join(@root, ".logs"), File.join(@root, ".jobs")])
    %w[legacy_conversion_context.py session_start.sh prompt_context.sh bash_conversion.sh
       stop_status.sh test_coverage_gate.sh ci_watch.sh].each do |name|
      FileUtils.cp(File.join(SOURCE, name), @hooks)
    end
    @environment = { "EPUB_LEGACY_CONTEXT" => "1", "EPUB_REVIEW_NOTICE" => nil }
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def invoke(name, payload = {}, environment = {})
    Open3.capture3(@environment.merge(environment), "bash", File.join(@hooks, name),
                   stdin_data: payload.is_a?(String) ? payload : JSON.generate(payload), chdir: @root)
  end

  def write_record(title = "Fixture book")
    File.write(File.join(@root, ".logs/conversions.jsonl"), JSON.generate(
      "book_title" => title, "engine" => "piper", "outcome" => "success") + "\n")
  end

  def test_opt_in_required_even_when_a_legacy_record_exists
    write_record
    output, error, status = invoke("session_start.sh", {}, "EPUB_LEGACY_CONTEXT" => nil)
    assert status.success?, error
    assert_empty output + error
  end

  def test_literal_checkout_root_reports_untrusted_history_without_running_analyzer
    write_record
    marker = File.join(@root, "analyzer-called")
    FileUtils.mkdir_p(File.join(@root, "scripts"))
    File.write(File.join(@root, "scripts/analyze_logs.py"), "from pathlib import Path\nPath(#{marker.inspect}).touch()\n")
    output, error, status = invoke("bash_conversion.sh", "tool_input" => { "command" => "mise run convert fixture.epub" })
    assert status.success?, error
    message = JSON.parse(output).fetch("systemMessage")
    assert_includes message, "Untrusted legacy compatibility observations"
    assert_includes message, "Fixture book"
    assert_includes message, "do not establish current Rust/native health or this command's outcome"
    refute File.exist?(marker)
  end

  def test_stop_is_advisory_and_repeated_stop_is_silent
    File.write(File.join(@root, ".jobs/other-task.json"), JSON.generate("state" => "running", "bookTitle" => "Other task"))
    output, error, status = invoke("stop_status.sh")
    assert status.success?, error
    observation = JSON.parse(output)
    refute observation.key?("decision")
    assert_includes observation.fetch("systemMessage"), "Other task"
    output, error, status = invoke("stop_status.sh", "stop_hook_active" => true)
    assert status.success?, error
    assert_empty output + error
  end

  def test_large_history_tail_ignores_partial_malformed_and_nonobject_records
    File.write(File.join(@root, ".logs/conversions.jsonl"),
      "x" * 100_000 + "\n{broken}\n[]\n" + JSON.generate("book_title" => "Tail fixture") + "\n")
    output, error, status = invoke("session_start.sh")
    assert status.success?, error
    assert_includes JSON.parse(output).fetch("systemMessage"), "Tail fixture"
    assert_operator output.bytesize, :<, 4096
  end

  def test_symlinked_job_outside_checkout_is_not_observed
    external = File.join(@temporary, "outside.json")
    File.write(external, JSON.generate("state" => "running", "bookTitle" => "Outside identity"))
    File.symlink(external, File.join(@root, ".jobs/link.json"))
    output, error, status = invoke("stop_status.sh")
    assert status.success?, error
    assert_empty output + error
  end

  def test_malformed_or_oversized_payloads_are_silent
    ["{broken}", "[]", " " * 65_537].each do |payload|
      output, error, status = invoke("session_start.sh", payload)
      assert status.success?, error
      assert_empty output + error
    end
  end

  def test_unrelated_prompt_or_command_does_not_load_history
    write_record
    [["prompt_context.sh", { "prompt" => "rename a button" }],
     ["bash_conversion.sh", { "tool_input" => { "command" => "git status" } }]].each do |name, payload|
      output, error, status = invoke(name, payload)
      assert status.success?, error
      assert_empty output + error
    end
  end

  def test_unrelated_checkout_edits_never_block_stop_or_start_ci
    File.write(File.join(@root, "unrelated.py"), "raise RuntimeError('unrelated work')\n")
    %w[test_coverage_gate.sh ci_watch.sh].each do |name|
      output, error, status = invoke(name, "tool_input" => { "command" => "git push" })
      assert status.success?, error
      assert_empty output
      refute_includes error, "decision"
    end
  end
end
