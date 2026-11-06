# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "simulator_safe_run"

class SimulatorCliTest < Minitest::Test
  class Backend
    attr_reader :identity
    def initialize(**identity)
      @identity = identity
    end
  end

  def test_missing_acknowledgement_refuses_without_backend_or_directory
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "report")
      _, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "simulator_safe_run.rb"),
        "--device", "fixture", "--app", "missing", "--report-directory", destination)
      assert_equal 75, status.exitstatus
      assert_match(/acknowledge/, error)
      refute File.exist?(destination)
    end
  end

  def test_acknowledged_cli_routes_exact_identity_to_supervisor_in_private_new_directory
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "report")
      arguments = ["--device", "fixture", "--app", "app", "--report-directory", destination, "--acknowledge-intel-panic-risk"]
      received = nil
      launcher = ->(**options) { received = options; 75 }
      assert_equal 75, SimulatorSafeRun.main(arguments.dup, backend_class: Backend, launcher: launcher)
      assert_equal "fixture", received[:backend].identity[:device]
      assert_equal "app", received[:backend].identity[:app]
      assert_equal false, received[:stable_existing_swap]
      assert_equal 0o700, File.stat(destination).mode & 0o777
      assert_equal File.join(File.realpath(destination), "report.json"), received[:report]
      received = nil
      capture_io { assert_equal 75, SimulatorSafeRun.main(arguments.dup, backend_class: Backend, launcher: launcher) }
      assert_nil received, "existing report directory must never run again"
    end
  end

  def test_existing_swap_exception_is_forwarded_only_by_explicit_flag
    Dir.mktmpdir do |dir|
      arguments = ["--device", "fixture", "--app", "app", "--report-directory", File.join(dir, "report"),
                   "--acknowledge-intel-panic-risk", "--allow-stable-existing-swap"]
      received = nil
      launcher = ->(**options) { received = options; 75 }
      assert_equal 75, SimulatorSafeRun.main(arguments, backend_class: Backend, launcher: launcher)
      assert_equal true, received[:stable_existing_swap]
    end
  end

  def test_observation_has_short_bounded_timing_and_cannot_mix_policies
    Dir.mktmpdir do |dir|
      args = ['--device', 'fixture', '--app', 'app', '--report-directory', File.join(dir, 'report'),
              '--acknowledge-intel-panic-risk', '--observe-resources']
      received = nil
      launcher = ->(**opts) { received = opts; 75 }
      assert_equal 75, SimulatorSafeRun.main(args.dup, backend_class: Backend, launcher: launcher)
      assert_equal true, received[:observe_resources]
      assert_equal 5, received[:baseline_seconds]
      assert_equal 180, received[:session_seconds]
      capture_io { assert_equal 75, SimulatorSafeRun.main(args + ['--allow-stable-existing-swap'], backend_class: Backend, launcher: launcher) }
    end
  end
end
