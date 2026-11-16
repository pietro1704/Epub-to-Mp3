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
