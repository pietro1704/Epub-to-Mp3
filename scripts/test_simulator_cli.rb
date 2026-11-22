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

  def test_missing_identity_refuses_without_backend_or_directory
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "report")
      _, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "simulator_safe_run.rb"),
        "--device", "fixture", "--report-directory", destination)
      assert_equal 75, status.exitstatus
      assert_match(/Requires --device, --app and --report-directory/, error)
      refute File.exist?(destination)
    end
  end

  def test_cli_needs_no_risk_acknowledgement_and_routes_exact_identity_to_supervisor_in_private_new_directory
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "report")
      arguments = ["--device", "fixture", "--app", "app", "--report-directory", destination]
      received = nil
      launcher = ->(**options) { received = options; 75 }
      assert_equal 75, SimulatorSafeRun.main(arguments.dup, backend_class: Backend, launcher: launcher)
      assert_equal "fixture", received[:backend].identity[:device]
      assert_equal "app", received[:backend].identity[:app]
      assert_equal %i[backend report sampler].sort, received.keys.sort, "no resource policy or timing option is forwarded"
      assert_equal 0o700, File.stat(destination).mode & 0o777
      assert_equal File.join(File.realpath(destination), "report.json"), received[:report]
      received = nil
      capture_io { assert_equal 75, SimulatorSafeRun.main(arguments.dup, backend_class: Backend, launcher: launcher) }
      assert_nil received, "existing report directory must never run again"
    end
  end

  def test_former_admission_flags_are_gone
    Dir.mktmpdir do |dir|
      %w[--acknowledge-intel-panic-risk --allow-stable-existing-swap --observe-resources].each do |flag|
        arguments = ["--device", "fixture", "--app", "app", "--report-directory", File.join(dir, flag), flag]
        launcher = ->(**) { flunk "#{flag} must not reach a session" }
        _, error = capture_io { assert_equal 75, SimulatorSafeRun.main(arguments, backend_class: Backend, launcher: launcher) }
        assert_match(/invalid option/, error, flag)
      end
    end
  end

  def test_tests_need_a_run_and_a_selector_but_no_observation_mode
    Dir.mktmpdir do |dir|
      base = ["--device", "fixture", "--app", "app", "--report-directory"]
      launcher = ->(**) { 75 }
      _, error = capture_io do
        assert_equal 75, SimulatorSafeRun.main([*base, File.join(dir, "a"), "--test-selector", "T/C/m"], backend_class: Backend, launcher: launcher)
      end
      assert_match(/Tests require a test run/, error)
    end
  end
end
