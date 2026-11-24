# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'yaml'

# Only five hosted macOS jobs run at once, so the post-merge run must not need more
# than five: CodeQL Swift x2, Faber arm64 and Intel, and one FFI artifact job (plus the iOS
# Simulator UIKit job, queued as a sixth).
class CiMacosJobBudgetTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def workflow(name) = YAML.load_file(File.join(ROOT, '.github/workflows', name))

  def macos_jobs(file, seen = {})
    workflow(file).fetch('jobs').sum do |_name, job|
      if job.key?('uses')
        nested = File.basename(job.fetch('uses'))
        seen.key?(nested) ? 0 : macos_jobs(nested, seen.merge(nested => true))
      elsif job.fetch('runs-on', '').to_s.match?(/macos/) || job.fetch('strategy', {}).fetch('matrix', {}).to_s.match?(/macos/)
        matrix = job.fetch('strategy', {}).fetch('matrix', nil)
        include = matrix&.fetch('include', nil)
        if include.is_a?(String) then JSON.parse(include[/'(\[\{"os":"macos-15","arch":"arm64"\},\{"os":"macos-15-intel"[^']+\])'/, 1]).size
        elsif include then include.size
        else 1
        end
      else 0
      end
    end
  end

  def test_post_merge_needs_at_most_five_macos_jobs
    post = workflow('post-merge-validation.yml').fetch('jobs')
    total = post.values.sum { |job| job.key?('uses') ? macos_jobs(File.basename(job.fetch('uses'))) : 0 }
    # ci.yml's Apple job is skipped in the integrated run, so it is not counted.
    ci_apple = macos_jobs('faber-integration.yml')
    assert_equal 2, ci_apple
    # The iOS Simulator UIKit job also runs in the integrated run (the pull request gate requires it
    # and there is no other post-merge execution of iOS-only UIKit code). GitHub queues the sixth
    # hosted macOS job behind the five concurrent slots; post-merge validation is batched, not per merge.
    ios_simulator = macos_jobs('ios-simulator-tests.yml')
    assert_equal 1, ios_simulator
    assert_equal 5 + ios_simulator, total - ci_apple
  end

  def test_native_and_isolation_are_steps_of_the_faber_arm64_job_not_separate_jobs
    post = workflow('post-merge-validation.yml').fetch('jobs')
    refute post.key?('native')
    refute post.key?('isolation')
    assert_equal true, post.fetch('faber').fetch('with').fetch('native_host_tests')
    refute_includes post.fetch('validated').fetch('needs'), 'native'
    refute_includes post.fetch('validated').fetch('needs'), 'isolation'
    steps = workflow('faber-integration.yml').fetch('jobs').fetch('macos-preferences').fetch('steps')
    run = steps.find { |step| step['name'] == 'Run only adapter isolation XCTest with the real bundled library' }
    refute_nil run
    assert_equal "matrix.arch == 'arm64' && inputs.macos_only != true", run.fetch('if')
    assert_includes run.fetch('run'), 'env -u EPUB2MP3_PIPER_TEST_MODEL_ROOT'
    refute_includes run.fetch('run'), 'EPUB2MP3_PIPER_TEST_MODEL_ROOT='
    assert_includes run.fetch('run'), '-only-testing:EpubToMp3Tests/ConverterFFIAdapterTests'
    original = File.read(File.join(ROOT, '.github/workflows/native-ffi-test-isolation.yml'))
    assert_includes original, '-only-testing:EpubToMp3Tests/ConverterFFIAdapterTests'
    require_five = steps.find { |step| step['name'].to_s.start_with?('Require all five adapter cases') }
    assert_includes require_five.fetch('run'), 'summary.fetch("passedTests") == 5 && summary.fetch("totalTestCount") == 5'
    assert_includes require_five.fetch('run'), 'summary.fetch("skippedTests") == 0 && summary.fetch("failedTests") == 0'
    names = steps.map { |step| step['name'] }
    assert_operator names.index(run['name']), :>, names.index('Run real macOS preference and installation XCTest')
  end
end
