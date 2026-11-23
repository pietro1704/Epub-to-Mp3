# frozen_string_literal: true

require 'minitest/autorun'

# GitHub-hosted runners are disposable VMs, so their build jobs follow the
# native_job.rb hosted allowance (or an explicit 3 for xcodebuild) instead of a
# serial pin. Test execution stays serial and local runs keep a single job.
class CiHostedParallelismTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def workflow(name) = File.read(File.join(ROOT, '.github/workflows', name))

  def test_hosted_workflows_no_longer_pin_one_build_job
    %w[cli-faber-golden converter-ffi native-hook-safety].each do |name|
      text = workflow("#{name}.yml")
      refute_match(/CARGO_BUILD_JOBS|CMAKE_BUILD_PARALLEL_LEVEL/, text, name)
      refute_match(/--jobs 1/, text, name)
    end
    refute_includes workflow('flutter-rust-faber.yml'), '--jobs 1'
  end

  def test_xcode_builds_use_three_jobs_with_serial_tests
    %w[faber-integration native-ffi-test-isolation].each do |name|
      text = workflow("#{name}.yml")
      assert_includes text, '-jobs 3 -parallel-testing-enabled NO', name
      refute_includes text, '-jobs 1', name
    end
  end

  def test_cli_package_follows_the_hosted_allowance_and_windows_stays_serial
    source = File.read(File.join(ROOT, 'scripts/package_rust_cli.rb'))
    assert_includes source, "'--jobs', (windows ? 1 : NativeJob.build_jobs).to_s"
    desktop = File.read(File.join(ROOT, 'scripts/build_flutter_desktop.rb'))
    assert_includes desktop, 'jobs = Gem.win_platform? && hosted ? Etc.nprocessors.clamp(1, 4).to_s : "1"'
    assert_includes desktop, 'ENV["RUNNER_ENVIRONMENT"] == "github-hosted"'
  end
end
