# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

# Executes the actual retry step against a fake gh; no service calls.
class RunnerAcquisitionRetryTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  MARKER = 'The job was not acquired by Runner of type hosted even after multiple attempts'
  HEAD = 'a' * 40

  def setup
    @workflow = YAML.load_file(File.join(ROOT, '.github/workflows/runner-acquisition-retry.yml'))
    @root = Dir.mktmpdir('runner-retry-')
    @log = File.join(@root, 'gh.log')
    File.write(File.join(@root, 'gh'), <<~RUBY)
      #!#{RbConfig.ruby}
      require 'json'
      File.open(ENV.fetch('GH_LOG'), 'a') { |file| file.puts ARGV.join(' ') }
      exit 0 if ARGV.first(2) == %w[run rerun]
      endpoint = ARGV.find { |argument| argument.start_with?('repos/') }.sub(/\\?.*/, '')
      print JSON.parse(File.read(ENV.fetch('GH_FIXTURE'))).fetch(endpoint)
    RUBY
    File.chmod(0o700, File.join(@root, 'gh'))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def job
    @workflow.fetch('jobs').fetch('retry')
  end

  def execute(jobs:, annotations: {}, attempt: 1, event: 'pull_request', current: HEAD, pr: '7')
    fixture = {
      'repos/o/r/actions/runs/9' => JSON.generate('run_attempt' => attempt),
      'repos/o/r/pulls/7' => current,
      'repos/o/r/commits/master' => current,
      'repos/o/r/actions/runs/9/attempts/1/jobs' => jobs.map { |id, name| "#{id}\t#{name}\n" }.join
    }
    annotations.each { |id, messages| fixture["repos/o/r/check-runs/#{id}/annotations"] = messages.join("\n") }
    File.write(File.join(@root, 'fixture.json'), JSON.generate(fixture))
    File.write(@log, '')
    environment = { 'PATH' => "#{@root}:#{ENV.fetch('PATH')}", 'GH_LOG' => @log,
      'GH_FIXTURE' => File.join(@root, 'fixture.json'), 'REPO' => 'o/r', 'RUN_ID' => '9',
      'HEAD_SHA' => HEAD, 'RUN_EVENT' => event, 'PR_NUMBER' => pr }
    _out, err, status = Open3.capture3(environment, 'bash', '-c', job.fetch('steps').first.fetch('run'))
    assert status.success?, err
    File.readlines(@log, chomp: true)
  end

  def rerun?(calls)
    calls.include?('run rerun 9 --failed --repo o/r')
  end

  def test_trigger_is_bounded_to_one_attempt_of_failed_gate_runs_with_minimal_permissions
    events = @workflow.fetch('on', @workflow[true])
    assert_equal({ 'workflows' => ['CI', 'Post-merge validation'], 'types' => ['completed'] }, events.fetch('workflow_run'))
    assert_equal({}, @workflow.fetch('permissions'))
    assert_equal({ 'actions' => 'write', 'checks' => 'read', 'contents' => 'read', 'pull-requests' => 'read' }, job.fetch('permissions'))
    assert_equal %q{contains(fromJSON('["failure", "cancelled"]'), github.event.workflow_run.conclusion) && github.event.workflow_run.run_attempt == 1}, job.fetch('if')
    # Observed on PR #1188: an unacquired macOS job ends as cancelled, not failed.
    assert_includes job.fetch('steps').first.fetch('run'), 'select(.conclusion == "failure" or .conclusion == "cancelled")'
    assert_equal 5, job.fetch('timeout-minutes')
    refute job.fetch('steps').any? { |step| step.key?('uses') }, 'No checkout or third-party code runs with actions: write'
  end

  def test_reruns_only_when_every_non_aggregate_failure_never_acquired_a_runner
    calls = execute(jobs: { 1 => 'Rust', 2 => 'PR gate' }, annotations: { 1 => [MARKER] })
    assert rerun?(calls)
    calls = execute(jobs: { 1 => 'Rust', 3 => 'Apple app tests / Faber macOS (arm64)', 2 => 'PR gate' },
      annotations: { 1 => [MARKER], 3 => ['Process completed with exit code 1.'] })
    refute rerun?(calls), 'A real failure must not be retried'
    calls = execute(jobs: { 2 => 'PR gate' }, annotations: {})
    refute rerun?(calls), 'An aggregate failure alone is not a runner failure'
    calls = execute(jobs: { 1 => 'Rust' }, annotations: { 1 => ['Due to capacity constraints, jobs may queue longer.'] })
    refute rerun?(calls)
  end

  def test_superseded_heads_and_already_retried_runs_are_left_unchanged
    jobs = { 1 => 'Rust' }
    annotations = { 1 => [MARKER] }
    refute rerun?(execute(jobs: jobs, annotations: annotations, attempt: 2))
    refute rerun?(execute(jobs: jobs, annotations: annotations, current: 'b' * 40))
    refute rerun?(execute(jobs: jobs, annotations: annotations, pr: ''))
    assert rerun?(execute(jobs: jobs, annotations: annotations, event: 'workflow_dispatch'))
    refute rerun?(execute(jobs: jobs, annotations: annotations, event: 'push', current: 'b' * 40))
  end
end
