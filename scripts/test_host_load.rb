# frozen_string_literal: true
require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "host_load"

# Fixtures are the readings taken on the Intel i5-8259U (8 logical CPUs, 8 GiB)
# after the CATERR report of 2026-11-19 21:35 BRT (2026-11-20 00:35 UTC); no
# host telemetry is read here.
class HostLoadTest < Minitest::Test
  SYSCTL_DURING_BUILD = <<~TEXT
    vm.loadavg: { 11.41 7.35 9.44 }
    vm.swapusage: total = 2048.00M  used = 1550.75M  free = 497.25M  (encrypted)
    vm.compressor_bytes_used: 1894268928
    kern.memorystatus_vm_pressure_level: 1
    hw.logicalcpu: 8
    hw.memsize: 8589934592
    machdep.xcpm.cpu_thermal_level: 112
  TEXT
  PMSET_DURING_BUILD = <<~TEXT
    Note: No thermal warning level has been recorded
    Note: No performance warning level has been recorded
    2026-11-19 22:12:17 -0300 CPU Power notify
    \tCPU_Scheduler_Limit \t= 100
    \tCPU_Available_CPUs \t= 8
    \tCPU_Speed_Limit \t= 81
  TEXT
  PS_DURING_BUILD = <<~TEXT
    107.0  8244     1 /System/Library/PrivateFrameworks/XprotectFramework.framework/Versions/A/XPCServices/XprotectService.xpc/Contents/MacOS/XprotectService
     97.8 48159 46029 /Applications/Xcode-26.3.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend
     48.4   511     1 /System/Library/PrivateFrameworks/FileProvider.framework/Support/fileproviderd
      0.4 46029 45965 /Applications/Xcode-26.3.0.app/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle/Contents/MacOS/SWBBuildService
      0.0 45965 45932 /Applications/Xcode-26.3.0.app/Contents/Developer/usr/bin/xcodebuild
      0.0 45932     1 /Users/someone/.local/share/mise/installs/ruby/4.0.7/bin/ruby
      0.0   600     1 /Applications/Some App.app/Contents/MacOS/Some App
  TEXT
  QUIET_PS = "  3.0   171     1 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer\n"
  COMPILERS = %w[cargo rustc xcodebuild swift-frontend swift-build clang].freeze
  IDLE = { "load" => [3.79, 6.58, 8.49], "cpus" => 8, "memory_mib" => 8192, "swap_used_mib" => 331.25,
           "swap_total_mib" => 2048.0, "compressor_mib" => 782, "pressure" => 1, "cpu_speed_limit" => 100,
           "cpu_scheduler_limit" => 100, "cpu_available" => 8, "thermal_level" => 52, "top" => [], "compilers" => [],
           "enclosing_build" => nil }.freeze

  def capture(sysctl, pmset, processes = QUIET_PS)
    lambda do |*argv, **|
      case argv.first
      when HostLoad::SYSCTL then sysctl
      when HostLoad::PMSET then pmset
      when HostLoad::PS then processes
      else flunk "unexpected probe #{argv.inspect}"
      end
    end
  end

  def sample(sysctl = SYSCTL_DURING_BUILD, pmset = PMSET_DURING_BUILD, processes = QUIET_PS)
    HostLoad.sample(capture: capture(sysctl, pmset, processes), compilers: COMPILERS)
  end

  def limits
    HostLoad.limits
  end

  def test_sample_parses_the_readings_taken_during_one_serial_ios_build
    reading = sample(SYSCTL_DURING_BUILD, PMSET_DURING_BUILD, PS_DURING_BUILD)
    assert_equal [11.41, 7.35, 9.44], reading["load"]
    assert_equal 8, reading["cpus"]
    assert_equal 8192, reading["memory_mib"]
    assert_in_delta 1550.75, reading["swap_used_mib"]
    assert_in_delta 2048.0, reading["swap_total_mib"]
    assert_equal 1807, reading["compressor_mib"]
    assert_equal 1, reading["pressure"]
    assert_equal [81, 100, 8], reading.values_at("cpu_speed_limit", "cpu_scheduler_limit", "cpu_available")
    assert_equal 112, reading["thermal_level"]
    assert_equal ["107.0 8244 XprotectService", "97.8 48159 swift-frontend", "48.4 511 fileproviderd"], reading["top"]
    assert_equal ["swift-frontend 48159", "xcodebuild 45965"], reading["compilers"]
    assert_nil reading["enclosing_build"]
    reasons = HostLoad.reasons(limits, reading)
    assert_equal 4, reasons.length, reasons.inspect
    assert_match(/1-minute load average 11\.41 exceeds 6\.00 \(75% of 8 CPUs\)/, reasons[0])
    assert_match(/swap in use 1551 MiB exceeds 1024 MiB/, reasons[1])
    assert_match(/CPU_Speed_Limit is 81/, reasons[2])
    assert_equal "a compiler is already running (swift-frontend 48159, xcodebuild 45965)", reasons[3]
  end

  def test_sample_accepts_comma_decimals_and_absent_optional_telemetry
    sysctl = SYSCTL_DURING_BUILD.sub("{ 11.41 7.35 9.44 }", "{ 3,79 6,58 8,49 }").sub("1550.75M", "331,25M")
                                .lines.reject { |line| line.start_with?("machdep") }.join
    reading = sample(sysctl, PMSET_DURING_BUILD.lines.first(2).join)
    assert_equal [3.79, 6.58, 8.49], reading["load"]
    assert_in_delta 331.25, reading["swap_used_mib"]
    assert_nil reading["thermal_level"]
    assert_equal [nil, nil, nil], reading.values_at("cpu_speed_limit", "cpu_scheduler_limit", "cpu_available")
    assert_equal ["3.0 171 WindowServer"], reading["top"]
    assert_empty reading["compilers"]
    assert_empty HostLoad.reasons(limits, reading), "no power notification since boot is not throttling"
  end

  def test_sample_rejects_incomplete_or_invalid_telemetry
    without_swap = SYSCTL_DURING_BUILD.lines.reject { |line| line.start_with?("vm.swapusage") }.join
    assert_match(/Missing vm\.swapusage/, assert_raises(RuntimeError) { sample(without_swap) }.message)
    assert_raises(RuntimeError) { sample(SYSCTL_DURING_BUILD.sub("pressure_level: 1", "pressure_level: 3")) }
    assert_raises(RuntimeError) { sample(SYSCTL_DURING_BUILD.sub("{ 11.41 7.35 9.44 }", "{ }")) }
  end

  def test_only_executable_names_identify_compilers_never_arguments_or_paths
    decoys = "  9.0 700 1 /Users/someone/cargo-tools/bin/helper\n  8.0 701 1 /usr/local/bin/clangd\n" \
             "  7.0 702 1 /usr/local/opt/rust/bin/cargo\n  6.0 703 702 /usr/local/opt/rust/bin/rustc\n"
    reading = sample(SYSCTL_DURING_BUILD, PMSET_DURING_BUILD, decoys)
    assert_equal ["cargo 702", "rustc 703"], reading["compilers"]
    assert_match(/a compiler is already running \(cargo 702, rustc 703\)/,
                 HostLoad.refusal(limits, IDLE.merge("compilers" => reading["compilers"])))
  end

  def test_an_enclosing_build_excuses_only_its_own_compilers_never_load_memory_or_thermal_limits
    own = Process.pid
    inside = "  90.0 9001 9000 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend\n" \
             "   0.1 #{own} 9002 /usr/bin/ruby\n   0.1 9002 9000 /bin/bash\n" \
             "   0.2 9000 8999 /Applications/Xcode.app/Contents/SharedFrameworks/SwiftBuild.framework/SWBBuildService\n" \
             "   1.0 8999 1 /Applications/Xcode.app/Contents/MacOS/Xcode\n"
    reading = sample(SYSCTL_DURING_BUILD, PMSET_DURING_BUILD, inside)
    assert_equal "SWBBuildService 9000", reading["enclosing_build"]
    assert_equal ["swift-frontend 9001"], reading["compilers"]
    reasons = HostLoad.reasons(limits, reading)
    assert_equal 3, reasons.length, "load, swap and thermal limits still refuse inside a build: #{reasons.inspect}"
    assert_match(/load average 11\.41/, reasons[0])
    assert_match(/swap in use 1551 MiB/, reasons[1])
    assert_match(/CPU_Speed_Limit is 81/, reasons[2])
    calm = IDLE.merge("compilers" => reading["compilers"], "enclosing_build" => reading["enclosing_build"])
    assert_nil HostLoad.refusal(limits, calm), "its own compilers alone do not refuse the step"
    { "pressure" => 2, "swap_used_mib" => 1550.75, "compressor_mib" => 4506, "cpu_scheduler_limit" => 50, "cpu_available" => 6 }.each do |key, value|
      refute_nil HostLoad.refusal(limits, calm.merge(key => value)), "#{key} must still refuse inside an enclosing build"
    end
    beside = inside.sub(" #{own} 9002 ", " #{own} 1 ")
    reading = sample(SYSCTL_DURING_BUILD, PMSET_DURING_BUILD, beside)
    assert_nil reading["enclosing_build"]
    assert_match(/a compiler is already running \(swift-frontend 9001\)/, HostLoad.refusal(limits, reading))
    driver = "   5.0 7000 1 /usr/local/opt/rust/bin/cargo\n   0.1 #{own} 7000 /usr/bin/ruby\n"
    reading = sample(SYSCTL_DURING_BUILD, PMSET_DURING_BUILD, driver)
    assert_equal "cargo 7000", reading["enclosing_build"]
    refute HostLoad.reasons(limits, reading).any? { |reason| reason.include?("compiler") }
    assert_nil HostLoad.refusal(limits, IDLE.merge("compilers" => ["cargo 7000"], "enclosing_build" => "cargo 7000"))
  end

  def test_measured_samples_without_a_heavy_job_are_admitted_and_overlapping_ones_are_refused
    [2.42, 2.56, 2.93, 3.79, 4.12, 4.96].each do |load|
      assert_nil HostLoad.refusal(limits, IDLE.merge("load" => [load, 0.0, 0.0])), load.to_s
    end
    [6.11, 7.12, 11.41, 14.0].each do |load|
      assert_match(/load average/, HostLoad.refusal(limits, IDLE.merge("load" => [load, 0.0, 0.0])), load.to_s)
    end
    # One serial build alone measured 4.24: the load average cannot tell it from
    # an idle host, the compiler names can.
    serial = IDLE.merge("load" => [4.24, 4.56, 5.86], "swap_used_mib" => 1016.0, "compilers" => ["swift-frontend 61379"])
    assert_equal ["a compiler is already running (swift-frontend 61379)"], HostLoad.reasons(limits, serial)
  end

  def test_each_memory_and_thermal_limit_refuses_on_its_own
    { { "swap_used_mib" => 563.25 } => nil, { "swap_used_mib" => 1550.75 } => /swap in use/,
      { "pressure" => 2 } => /memory pressure is warning/, { "pressure" => 4 } => /memory pressure is critical/,
      { "compressor_mib" => 2040 } => nil, { "compressor_mib" => 4506 } => /compressor occupies 55% of memory, above 50%/,
      { "cpu_speed_limit" => 81 } => /CPU_Speed_Limit is 81/, { "cpu_scheduler_limit" => 50 } => /CPU_Scheduler_Limit is 50/,
      { "cpu_available" => 6 } => /only 6 of 8 CPUs/ }.each do |change, expected|
      message = HostLoad.refusal(limits, IDLE.merge(change))
      expected ? assert_match(expected, message, change.inspect) : assert_nil(message, change.inspect)
    end
    message = HostLoad.refusal(limits, IDLE.merge("pressure" => 2, "cpu_speed_limit" => 81))
    assert_match(/memory pressure is warning; CPU_Speed_Limit is 81/, message)
    assert_match(/native_job\.rb status/, message)
  end

  def test_check_blocks_when_telemetry_or_policy_cannot_be_read
    assert_nil HostLoad.check(sampler: -> { IDLE })
    assert_match(/inspection failed \(RuntimeError: probe\); heavy job blocked/,
                 HostLoad.check(sampler: -> { raise "probe" }))
    assert_match(/inspection failed/, HostLoad.check(sampler: -> { IDLE }, policy: -> { raise KeyError, "limits" }))
  end

  def test_limits_require_every_non_negative_integer_and_a_compiler_list
    assert_equal (HostLoad::LIMITS + ["foreign_compilers"]).sort, limits.keys.sort
    assert_equal COMPILERS, limits.fetch("foreign_compilers")
    Dir.mktmpdir("host-load-") do |directory|
      path = File.join(directory, "policy.json")
      File.write(path, JSON.generate("version" => 1))
      assert_match(/Missing admission/, assert_raises(RuntimeError) { HostLoad.limits(path) }.message)
      valid = limits
      { "max_swap_used_mib" => -1, "max_load_percent_of_cpus" => 0.75, "recheck_seconds" => 0, "child_niceness" => nil,
        "foreign_compilers" => "cargo" }.each do |key, value|
        File.write(path, JSON.generate("admission" => valid.merge(key => value)))
        assert_match(/Invalid admission #{key}/, assert_raises(RuntimeError) { HostLoad.limits(path) }.message)
      end
    end
  end

  def test_capture_uses_a_fixed_locale_and_a_deadline
    assert_equal "C\n", HostLoad.capture("/bin/sh", "-c", "echo $LC_ALL")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(RuntimeError) { HostLoad.capture("/bin/sleep", "20", seconds: 0.2) }
    assert_match(/sleep telemetry deadline exceeded/, error.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end
end
