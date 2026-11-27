# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

# The default iOS Simulator selection lives in its own file, one class per line, so that
# pull requests adding a class no longer collide on a single comma-separated workflow line.
class IosSimulatorTestListTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  LIST = '.github/ios-simulator-test-classes.txt'

  def classes
    File.readlines(File.join(ROOT, LIST), chomp: true).reject { |line| line.empty? || line.start_with?('#') }
  end

  def run_step
    workflow = YAML.load_file(File.join(ROOT, '.github/workflows/ios-simulator-tests.yml'))
    workflow.fetch('jobs').fetch('ios-simulator').fetch('steps')
            .find { |step| step['name'] == 'Run iOS XCTest on the Simulator' }.fetch('run')
  end

  # Runs the real selection lines of the workflow step with the system bash.
  def selection(requested, list_contents)
    script = run_step[/\A.*?(?=^report=)/m]
    Dir.mktmpdir do |directory|
      working = File.join(directory, 'ios/EpubToMp3')
      FileUtils.mkdir_p([working, File.join(directory, '.github')])
      File.write(File.join(directory, LIST), list_contents) if list_contents
      Open3.capture3({ 'TEST_CLASSES' => requested }, '/bin/bash', '-c', "#{script}\nprintf '%s\\n' \"${only[@]}\"", chdir: working)
    end
  end

  def test_list_is_one_sorted_unique_existing_class_per_line
    refute_empty classes
    assert_equal classes.sort, classes, 'keep the list sorted'
    assert_equal classes.uniq, classes
    sources = Dir[File.join(ROOT, 'ios/EpubToMp3/EpubToMp3Tests/**/*.swift')].map { |path| File.read(path) }.join
    missing = classes.reject { |name| name.match?(/\A\w+\z/) && sources.match?(/\bclass\s+#{name}\b/) }
    assert_empty missing, 'every line names a test class'
  end

  def test_empty_input_selects_every_listed_class_and_skips_comments
    output, error, status = selection('', "# comment\nAlphaTests\n\nBetaTests\n")
    assert status.success?, error
    assert_equal %w[-only-testing:EpubToMp3Tests/AlphaTests -only-testing:EpubToMp3Tests/BetaTests], output.split
  end

  def test_requested_classes_replace_the_list
    output, error, status = selection('GammaTests, DeltaTests', "AlphaTests\n")
    assert status.success?, error
    assert_equal %w[-only-testing:EpubToMp3Tests/GammaTests -only-testing:EpubToMp3Tests/DeltaTests], output.split
  end

  def test_missing_or_empty_list_fails_instead_of_running_an_unintended_selection
    [nil, "# only a comment\n"].each do |contents|
      _output, _error, status = selection('', contents)
      refute status.success?, "list #{contents.inspect} must fail the step"
    end
  end

  # `mise run` exports CARGO_HOME/RUSTUP_HOME to the task. A nested `mise exec` then treats the
  # homes as explicit, misses the runner's external rustup and reinstalls Rust over the network.
  # Only the explicit `mise install` step may install tools (CI-IOS-MISE-RUST-REINSTALL).
  def test_only_the_explicit_install_step_may_install_tools
    job = YAML.load_file(File.join(ROOT, '.github/workflows/ios-simulator-tests.yml')).fetch('jobs').fetch('ios-simulator')
    assert_equal 'false', job.fetch('env')['MISE_EXEC_AUTO_INSTALL']
    assert_equal 'false', job.fetch('env')['MISE_TASK_RUN_AUTO_INSTALL']
    assert(job.fetch('steps').any? { |step| step['run'] == 'mise install' })
  end
end
