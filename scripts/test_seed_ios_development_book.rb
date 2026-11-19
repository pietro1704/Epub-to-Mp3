# frozen_string_literal: true

# Tests for the iOS development-book staging helper (ported from test_seed_ios_development_book.py).
# xcrun is always a fake on PATH or an injected runner; no simulator or device is touched.

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require_relative 'seed_ios_development_book'

class SeedIosDevelopmentBookTest < Minitest::Test
  SCRIPT = File.expand_path('seed_ios_development_book.rb', __dir__)
  Seed = SeedIosDevelopmentBook

  def setup
    @root = Dir.mktmpdir('seed ios book ')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def write(path, bytes)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
    path
  end

  def fake_xcrun(script)
    bin = File.join(@root, 'bin')
    write(File.join(bin, 'xcrun'), "#!/bin/sh\n#{script}")
    FileUtils.chmod(0o755, File.join(bin, 'xcrun'))
    bin
  end

  def run_script(*args, env: {})
    base = { 'HOME' => File.join(@root, 'home'), 'IOS_DEVELOPMENT_SEED_SOURCE' => nil,
             'IOS_DEVELOPMENT_SEED_BOOK' => nil }
    Open3.capture3(base.merge(env), RbConfig.ruby, SCRIPT, *args)
  end

  def test_explicit_seed_source_takes_precedence_over_legacy_configuration
    source = write(File.join(@root, 'book.epub'), 'epub')
    legacy = write(File.join(@root, 'legacy.epub'), 'legacy')
    env = { 'IOS_DEVELOPMENT_SEED_SOURCE' => source, 'IOS_DEVELOPMENT_SEED_BOOK' => legacy }

    assert_equal source, Seed.development_book_source(env: env)
  end

  def test_boolean_seed_flag_is_not_treated_as_a_source_path
    write(File.join(@root, '1'), 'not a book')
    Dir.chdir(@root) do
      assert_nil Seed.development_book_source(env: { 'IOS_DEVELOPMENT_SEED_BOOK' => '1' }, home: @root)
    end
  end

  # --- Ruby-only coverage of the CLI contract ---

  def test_legacy_path_is_used_when_explicit_source_is_blank
    legacy = write(File.join(@root, 'legacy.epub'), 'legacy')
    env = { 'IOS_DEVELOPMENT_SEED_SOURCE' => '  ', 'IOS_DEVELOPMENT_SEED_BOOK' => " #{legacy} " }
    assert_equal legacy, Seed.development_book_source(env: env)
    assert_nil Seed.development_book_source(env: { 'IOS_DEVELOPMENT_SEED_BOOK' => '0' }, home: @root)
  end

  def test_default_candidates_prefer_ebooks_then_ebook_and_expand_user
    second = write(File.join(@root, 'Downloads/ebook', Seed::DEFAULT_BOOK), 'b')
    assert_equal second, Seed.development_book_source(env: {}, home: @root)
    first = write(File.join(@root, 'Downloads/Ebooks', Seed::DEFAULT_BOOK), 'a')
    assert_equal first, Seed.development_book_source(env: {}, home: @root)
    assert_equal "#{Dir.home}/x/../y", Seed.expand_user('~/x/../y')
    assert_equal 'relative/book.epub', Seed.expand_user('relative/book.epub')
  end

  def test_missing_source_exits_three_without_calling_xcrun
    bin = fake_xcrun("echo called > '#{@root}/called'\n")
    stdout, stderr, status = run_script('--target', 'device', '--identifier', 'DEV',
                                        env: { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}" })
    assert_equal 3, status.exitstatus
    assert_equal '', stdout
    assert_equal "ios development seed skipped: source EPUB is unavailable\n", stderr
    refute File.exist?(File.join(@root, 'called'))
  end

  def test_simulator_staging_copies_into_container_documents_through_fake_xcrun
    source = write(File.join(@root, 'My Book.epub'), 'epub bytes')
    container = File.join(@root, 'container data')
    bin = fake_xcrun("echo \"$@\" > '#{@root}/args'\necho '  #{container}  '\n")
    stdout, stderr, status = run_script('--target', 'simulator', '--identifier', 'UDID-1',
                                        env: { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}",
                                               'IOS_DEVELOPMENT_SEED_SOURCE' => source })
    target = File.join(container, 'Documents', Seed::STAGED_FILENAME)
    assert_equal 0, status.exitstatus, stderr
    assert_equal "ios development seed → My Book.epub → #{target}\n", stdout
    assert_equal "simctl get_app_container UDID-1 com.pietrocode.epubtomp3 data\n", File.read(File.join(@root, 'args'))
    assert_equal 'epub bytes', File.binread(target)
  end

  def test_simulator_staging_skips_same_size_copy_and_replaces_different_size
    source = write(File.join(@root, 'book.epub'), 'new!')
    container = File.join(@root, 'container')
    target = write(File.join(container, 'Documents', Seed::STAGED_FILENAME), 'old!')
    runner = ->(_command) { "#{container}\n" }
    assert_equal target, Seed.stage_for_simulator(source, 'U', runner: runner)
    assert_equal 'old!', File.binread(target)
    File.binwrite(source, 'longer')
    Seed.stage_for_simulator(source, 'U', runner: runner)
    assert_equal 'longer', File.binread(target)
  end

  def test_empty_container_output_resolves_relative_to_current_directory
    source = write(File.join(@root, 'book.epub'), 'x')
    work = File.join(@root, 'cwd')
    FileUtils.mkdir_p(work)
    Dir.chdir(work) do
      target = Seed.stage_for_simulator(source, 'U', runner: ->(_command) { "\n" })
      assert_equal "./Documents/#{Seed::STAGED_FILENAME}", target
      assert File.file?(File.join(work, 'Documents', Seed::STAGED_FILENAME))
    end
  end

  def test_device_staging_passes_exact_devicectl_arguments
    calls = []
    destination = Seed.stage_for_device('/books/a.epub', 'DEVICE-ID', runner: ->(command) { calls << command })
    assert_equal "Documents/#{Seed::STAGED_FILENAME}", destination
    assert_equal [['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', 'DEVICE-ID', '--source', '/books/a.epub',
                   '--destination', destination, '--domain-type', 'appDataContainer',
                   '--domain-identifier', 'com.pietrocode.epubtomp3']], calls
  end

  def test_xcrun_failure_reports_stderr_and_exits_one
    source = write(File.join(@root, 'book.epub'), 'x')
    bin = fake_xcrun("echo '  device locked  ' >&2\nexit 7\n")
    stdout, stderr, status = run_script('--target', 'device', '--identifier', 'DEV',
                                        env: { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}",
                                               'IOS_DEVELOPMENT_SEED_SOURCE' => source })
    assert_equal 1, status.exitstatus
    assert_equal '', stdout
    assert_equal "device locked\n", stderr
  end

  def test_silent_xcrun_failure_reports_called_process_error_text
    source = write(File.join(@root, 'book.epub'), 'x')
    stdout = StringIO.new
    stderr = StringIO.new
    failing = ->(command) { raise Seed::CommandError.new(command, 5, '') }
    status = Seed.main(%w[--target simulator --identifier U], env: { 'IOS_DEVELOPMENT_SEED_SOURCE' => source },
                                                              stdout: stdout, stderr: stderr, runner: failing)
    assert_equal 1, status
    assert_equal "Command '['xcrun', 'simctl', 'get_app_container', 'U', 'com.pietrocode.epubtomp3', 'data']' " \
                 "returned non-zero exit status 5.\n", stderr.string
  end

  def test_argument_errors_match_argparse_and_exit_two
    usage = "usage: seed_ios_development_book.rb [-h] --target {simulator,device}\n" \
            "                                    --identifier IDENTIFIER\n"
    {
      [] => 'the following arguments are required: --target, --identifier',
      %w[--target device] => 'the following arguments are required: --identifier',
      %w[--target phone --identifier X] => "argument --target: invalid choice: 'phone' (choose from 'simulator', 'device')",
      %w[--identifier] => 'argument --identifier: expected one argument',
      %w[--identifier --target device] => 'argument --identifier: expected one argument',
      %w[--target device --identifier X extra] => 'unrecognized arguments: extra'
    }.each do |argv, message|
      stdout, stderr, status = run_script(*argv)
      assert_equal 2, status.exitstatus, argv.inspect
      assert_equal '', stdout
      assert_equal "#{usage}seed_ios_development_book.rb: error: #{message}\n", stderr, argv.inspect
    end
  end

  def test_abbreviated_and_equals_options_and_help
    options, status = Seed.parse_arguments(%w[--tar=device --id -5], stdout: StringIO.new, stderr: StringIO.new)
    assert_nil status
    assert_equal({ target: 'device', identifier: '-5' }, options)
    stdout = StringIO.new
    _, status = Seed.parse_arguments(%w[-h], stdout: stdout, stderr: StringIO.new)
    assert_equal 0, status
    assert_includes stdout.string, Seed::DESCRIPTION
  end
end
