# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

# Runs the real ./convert wrapper against a stub mise; no build or conversion starts.
class ConvertEntrypointTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def setup
    @directory = File.realpath(Dir.mktmpdir('convert entrypoint '))
    @bin = File.join(@directory, 'bin')
    @record = File.join(@directory, 'record')
    FileUtils.mkdir_p(@bin)
    File.write(File.join(@bin, 'mise'), <<~SH)
      #!/usr/bin/env bash
      { pwd; printf '%s\\n' "$@"; } > "$CONVERT_RECORD"
      exit "${MISE_STATUS:-0}"
    SH
    File.chmod(0o755, File.join(@bin, 'mise'))
    @caller = File.join(@directory, 'caller dir')
    FileUtils.mkdir_p(File.join(@caller, 'books'))
    File.write(File.join(@caller, 'books', 'My Book.epub'), 'fixture')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def invoke(*arguments, environment: {})
    env = { 'PATH' => "#{@bin}:/usr/bin:/bin", 'CONVERT_RECORD' => @record }.merge(environment)
    Open3.capture3(env, File.join(ROOT, 'convert'), *arguments, chdir: @caller)
  end

  def recorded
    File.readlines(@record, chomp: true)
  end

  def test_runs_the_rust_convert_task_from_the_repository_root
    _, error, status = invoke('books/My Book.epub', '--chapter', '5')
    assert status.success?, error
    lines = recorded
    assert_equal File.realpath(ROOT), File.realpath(lines.first)
    assert_equal ['run', 'convert', '--', File.join(@caller, 'books', 'My Book.epub'), '--chapter', '5'], lines.drop(1)
  end

  def test_keeps_fuzzy_queries_absolute_paths_and_flags_literal
    _, error, status = invoke('Missing Title', '/abs/book.epub', '--verify')
    assert status.success?, error
    assert_equal ['run', 'convert', '--', 'Missing Title', '/abs/book.epub', '--verify'], recorded.drop(1)
  end

  def test_option_values_stay_literal_when_they_match_existing_paths
    %w[piper 5].each { |name| FileUtils.mkdir_p(File.join(@caller, name)) }
    _, error, status = invoke('books/My Book.epub', '--engine', 'piper', '--chapter', '5', '--section', '5', '--retry-failed', '5', '--from-chapter-to-end', '5')
    assert status.success?, error
    assert_equal ['run', 'convert', '--', File.join(@caller, 'books', 'My Book.epub'),
                  '--engine', 'piper', '--chapter', '5', '--section', '5', '--retry-failed', '5', '--from-chapter-to-end', '5'], recorded.drop(1)
  end

  def test_paths_after_boolean_flags_and_path_options_are_still_resolved
    FileUtils.mkdir_p(File.join(@caller, 'models'))
    File.write(File.join(@caller, 'models', 'voice.onnx'), 'fixture')
    _, error, status = invoke('--yes', 'books/My Book.epub', '--model', 'models/voice.onnx')
    assert status.success?, error
    assert_equal ['run', 'convert', '--', '--yes', File.join(@caller, 'books', 'My Book.epub'),
                  '--model', File.join(@caller, 'models', 'voice.onnx')], recorded.drop(1)
  end

  def test_output_and_manifest_paths_resolve_from_the_caller_even_when_missing
    _, error, status = invoke(
      'books/My Book.epub', '--output-dir', 'new out', '--batch-file', 'queue.txt',
      '--output-dir', '/abs/out'
    )
    assert status.success?, error
    assert_equal ['run', 'convert', '--', File.join(@caller, 'books', 'My Book.epub'),
                  '--output-dir', File.join(@caller, 'new out'),
                  '--batch-file', File.join(@caller, 'queue.txt'),
                  '--output-dir', '/abs/out'], recorded.drop(1)
  end

  def test_runs_without_arguments_and_preserves_failure_status
    _, _, status = invoke(environment: { 'MISE_STATUS' => '7' })
    assert_equal 7, status.exitstatus
    assert_equal %w[run convert --], recorded.drop(1)
  end

  def test_refuses_without_mise
    FileUtils.rm(File.join(@bin, 'mise'))
    _, error, status = invoke('books/My Book.epub')
    refute status.success?
    assert_includes error, 'mise not found'
    refute File.exist?(@record)
  end
end
