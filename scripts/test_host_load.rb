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
  FIXTURE_READER_PID = 8000
  IDLE = { "load" => [3.79, 6.58, 8.49], "cpus" => 8, "memory_mib" => 8192, "swap_used_mib" => 331.25,
           "swap_total_mib" => 2048.0, "compressor_mib" => 782, "pressure" => 1, "cpu_speed_limit" => 100,
           "cpu_scheduler_limit" => 100, "cpu_available" => 8, "thermal_level" => 52, "top" => [], "compilers" => [],
           "own_compilers" => [], "enclosing_build" => nil }.freeze

  # A real process list always contains the reader itself; fixtures get that row
  # appended unless they place this process somewhere on purpose.
  def own_row(processes)
    processes.match?(/^\s*\S+\s+#{FIXTURE_READER_PID}\s/) ? processes : "#{processes}  0.0 #{FIXTURE_READER_PID} 1 /usr/bin/ruby\n"
  end

  def capture(sysctl, pmset, processes = QUIET_PS)
    @probes = []
    lambda do |*argv, **options|
      @probes << [File.basename(argv.first), argv.drop(1), options]
      case argv.first
      when HostLoad::SYSCTL then sysctl
      when HostLoad::PMSET then pmset
      when HostLoad::PS then own_row(processes)
      else flunk "unexpected probe #{argv.inspect}"
      end
    end
  end

  def sample(sysctl = SYSCTL_DURING_BUILD, pmset = PMSET_DURING_BUILD, processes = QUIET_PS,
             capture: self.capture(sysctl, pmset, processes))
    HostLoad.sample(capture: capture, compilers: COMPILERS, current_pid: FIXTURE_READER_PID)
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
    reasons = HostLoad.notes(limits, reading)
    assert_equal 3, reasons.length, reasons.inspect
    assert_match(/1-minute load average 11\.41 exceeds 6\.00 \(75% of 8 CPUs\)/, reasons[0])
    assert_match(/CPU_Speed_Limit is 81/, reasons[1])
    assert_equal "a compiler is already running (swift-frontend 48159, xcodebuild 45965)", reasons[2]
  end

  def test_sample_accepts_comma_decimals_and_absent_optional_telemetry
    sysctl = SYSCTL_DURING_BUILD.sub("{ 11.41 7.35 9.44 }", "{ 3,79 6,58 8,49 }").sub("1550.75M", "331,25M")
                                .lines.reject { |line| line.start_with?("machdep") }.join
    reading = sample(sysctl, PMSET_DURING_BUILD.lines.first(2).join)
    assert_equal [3.79, 6.58, 8.49], reading["load"]
    assert_in_delta 331.25, reading["swap_used_mib"]
    assert_nil reading["thermal_level"]
    assert_equal [nil, nil, nil], reading.values_at("cpu_speed_limit", "cpu_scheduler_limit", "cpu_available")
    assert_equal ["3.0 171 WindowServer", "0.0 #{FIXTURE_READER_PID} ruby"], reading["top"]
    assert_empty reading["compilers"]
    assert_empty HostLoad.notes(limits, reading), "no power notification since boot is not throttling"
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
                 HostLoad.notes(limits, IDLE.merge("compilers" => reading["compilers"])).join)
  end

  def test_an_enclosing_build_excuses_only_its_own_compilers_never_load_or_thermal_notes
    own = FIXTURE_READER_PID
    inside = "  90.0 9001 9000 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend\n" \
             "   0.1 #{own} 9002 /usr/bin/ruby\n   0.1 9002 9000 /bin/bash\n" \
             "   0.2 9000 8999 /Applications/Xcode.app/Contents/SharedFrameworks/SwiftBuild.framework/SWBBuildService\n" \
             "   1.0 8999 1 /Applications/Xcode.app/Contents/MacOS/Xcode\n"
    reading = sample(SYSCTL_DURING_BUILD, PMSET_DURING_BUILD, inside)
    assert_equal "SWBBuildService 9000", reading["enclosing_build"]
    assert_equal ["swift-frontend 9001"], reading["compilers"]
    assert_equal ["swift-frontend 9001"], reading["own_compilers"]
    reasons = HostLoad.notes(limits, reading)
    assert_equal 2, reasons.length, "load and thermal notes remain inside a build: #{reasons.inspect}"
    assert_match(/load average 11\.41/, reasons[0])
    assert_match(/CPU_Speed_Limit is 81/, reasons[1])
    calm = IDLE.merge(reading.slice("compilers", "own_compilers", "enclosing_build"))
    assert_empty HostLoad.notes(limits, calm), "its own compilers alone are not foreign"
    { "pressure" => 2, "load" => [7.12, 4.46, 8.85], "cpu_scheduler_limit" => 50, "cpu_available" => 6 }.each do |key, value|
      refute_empty HostLoad.notes(limits, calm.merge(key => value)), "#{key} is still noted inside an enclosing build"
    end
    beside = inside.sub(" #{own} 9002 ", " #{own} 1 ")
    reading = sample(SYSCTL_DURING_BUILD, PMSET_DURING_BUILD, beside)
    assert_nil reading["enclosing_build"]
    assert_match(/a compiler is already running \(swift-frontend 9001\)/, HostLoad.notes(limits, reading).join)
    driver = "   5.0 7000 1 /usr/local/opt/rust/bin/cargo\n   0.1 #{own} 7000 /usr/bin/ruby\n"
    reading = sample(SYSCTL_DURING_BUILD, PMSET_DURING_BUILD, driver)
    assert_equal "cargo 7000", reading["enclosing_build"]
    assert_equal ["cargo 7000"], reading["own_compilers"], "the enclosing compiler driver is its own build"
    refute HostLoad.notes(limits, reading).any? { |reason| reason.include?("compiler") }
  end

  def test_an_enclosing_build_does_not_excuse_a_compiler_it_did_not_start
    own = FIXTURE_READER_PID
    processes = "  90.0 9001 9000 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend\n" \
                "  80.0 9003 9001 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang\n" \
                "  70.0 7000 1 /usr/local/opt/rust/bin/cargo\n  60.0 7001 7000 /usr/local/opt/rust/bin/rustc\n" \
                "   0.1 #{own} 9002 /usr/bin/ruby\n   0.1 9002 9000 /bin/bash\n" \
                "   0.2 9000 8999 /Applications/Xcode.app/Contents/SharedFrameworks/SwiftBuild.framework/SWBBuildService\n" \
                "   1.0 8999 1 /Applications/Xcode.app/Contents/MacOS/Xcode\n"
    reading = sample(SYSCTL_DURING_BUILD, PMSET_DURING_BUILD, processes)
    assert_equal "SWBBuildService 9000", reading["enclosing_build"]
    assert_equal ["swift-frontend 9001", "clang 9003", "cargo 7000", "rustc 7001"], reading["compilers"]
    calm = IDLE.merge(reading.slice("compilers", "own_compilers", "enclosing_build"))
    assert_equal ["a compiler is already running (cargo 7000, rustc 7001)"], HostLoad.notes(limits, calm),
                 "a package-manager build beside the enclosing Xcode build is still another job"
    assert_equal ["swift-frontend 9001", "clang 9003"], reading["own_compilers"]
    # A compiler driver started by that build is one more build this step runs inside.
    nested = processes.sub(" #{own} 9002 ", " #{own} 9004 ") +
             "  50.0 9004 9002 /usr/local/opt/rust/bin/cargo\n  40.0 9005 9004 /usr/local/opt/rust/bin/rustc\n"
    reading = sample(SYSCTL_DURING_BUILD, PMSET_DURING_BUILD, nested)
    assert_equal "cargo 9004", reading["enclosing_build"], "the nearest one is named"
    assert_equal ["swift-frontend 9001", "clang 9003", "cargo 9004", "rustc 9005"], reading["own_compilers"]
    calm = IDLE.merge(reading.slice("compilers", "own_compilers", "enclosing_build"))
    assert_equal ["a compiler is already running (cargo 7000, rustc 7001)"], HostLoad.notes(limits, calm)
  end

  def test_a_probe_that_fails_or_answers_nothing_is_a_note_never_a_silent_clean_reading
    assert_match(/false failed \(exit 1\)/, assert_raises(RuntimeError) { HostLoad.capture("/usr/bin/false") }.message)
    assert_equal "", HostLoad.capture("/usr/bin/false", tolerate_failure: true)
    failing = lambda do |tool|
      lambda do |*argv, **|
        raise "#{File.basename(tool)} failed (exit 1)" if argv.first == tool

        capture(SYSCTL_DURING_BUILD.sub("{ 11.41 7.35 9.44 }", "{ 4.24 4.56 5.86 }").sub("1550.75M", "331.25M"),
                PMSET_DURING_BUILD.sub("= 81", "= 100")).call(*argv)
      end
    end
    assert_empty HostLoad.assess(sampler: -> { sample(capture: failing.call("/nothing")) })
    [HostLoad::PS, HostLoad::PMSET, HostLoad::SYSCTL].each do |tool|
      message = HostLoad.assess(sampler: -> { sample(capture: failing.call(tool)) })
      assert_equal ["host load inspection failed (RuntimeError: #{File.basename(tool)} failed (exit 1))"], message
    end
    no_processes = ->(*argv, **) { argv.first == HostLoad::PS ? "" : capture(SYSCTL_DURING_BUILD, PMSET_DURING_BUILD).call(*argv) }
    assert_match(/Invalid process telemetry/, assert_raises(RuntimeError) { sample(capture: no_processes) }.message)
    assert_match(/Invalid thermal telemetry/, assert_raises(RuntimeError) { sample(SYSCTL_DURING_BUILD, "\n") }.message)
    sample
    assert_equal [["sysctl", HostLoad::REQUIRED, {}], ["sysctl", HostLoad::OPTIONAL, { tolerate_failure: true }]], @probes.first(2),
                 "only the optional names may make sysctl exit non-zero"
    assert_equal [["pmset", {}], ["ps", {}]], @probes.drop(2).map { |name, _, options| [name, options] }
    # A host without the optional name: that call fails and answers nothing.
    required = SYSCTL_DURING_BUILD.lines.reject { |line| line.start_with?("machdep") }.join
    without_optional = lambda do |*argv, **options|
      options[:tolerate_failure] ? "" : capture(required, PMSET_DURING_BUILD).call(*argv, **options)
    end
    reading = sample(capture: without_optional)
    assert_equal [nil, [11.41, 7.35, 9.44]], reading.values_at("thermal_level", "load")
  end

  def test_measured_samples_are_noted_only_when_they_overlap_other_work
    [2.42, 2.56, 2.93, 3.79, 4.12, 4.96].each do |load|
      assert_empty HostLoad.notes(limits, IDLE.merge("load" => [load, 0.0, 0.0])), load.to_s
    end
    [6.11, 7.12, 11.41, 14.0].each do |load|
      assert_match(/load average/, HostLoad.notes(limits, IDLE.merge("load" => [load, 0.0, 0.0])).join, load.to_s)
    end
    # One serial build alone measured 4.24: the load average cannot tell it from
    # an idle host, the compiler names can.
    serial = IDLE.merge("load" => [4.24, 4.56, 5.86], "swap_used_mib" => 1016.0, "compilers" => ["swift-frontend 61379"])
    assert_equal ["a compiler is already running (swift-frontend 61379)"], HostLoad.notes(limits, serial)
  end

  STRESS = { { "pressure" => 2 } => /memory pressure is warning/, { "pressure" => 4 } => /memory pressure is critical/,
             { "cpu_speed_limit" => 81 } => /CPU_Speed_Limit is 81/, { "cpu_scheduler_limit" => 50 } => /CPU_Scheduler_Limit is 50/,
             { "cpu_available" => 6 } => /only 6 of 8 CPUs/, { "load" => [7.12, 4.46, 8.85] } => /1-minute load average 7\.12 exceeds 6\.00/,
             { "compilers" => ["cargo 61001"] } => /a compiler is already running \(cargo 61001\)/ }.freeze

  def test_memory_pressure_each_thermal_limit_load_and_a_foreign_compiler_are_notes_on_their_own
    STRESS.each do |change, expected|
      assert_match(expected, HostLoad.notes(limits, IDLE.merge(change)).join, change.inspect)
      assert_equal 1, HostLoad.notes(limits, IDLE.merge(change)).length, change.inspect
    end
    assert_equal ["memory pressure is warning", "CPU_Speed_Limit is 81 (thermal throttling)"],
                 HostLoad.notes(limits, IDLE.merge("pressure" => 2, "cpu_speed_limit" => 81))
  end

  def test_the_refusal_and_wait_api_is_gone
    %i[reasons refusal advice warnings].each { |name| refute_respond_to HostLoad, name }
    assert_empty HostLoad::LIMITS & %w[recheck_seconds default_wait_seconds max_load_percent_of_cpus]
  end

  # 00:32 BRT on 2026-11-20 (03:32 UTC): no lease holder, no compiler, no thermal limit, normal memory pressure.
  IDLE_WITH_OLD_SWAP = IDLE.merge("load" => [3.32, 3.77, 3.77], "swap_used_mib" => 1192.75, "compressor_mib" => 368).freeze

  def test_swap_and_the_compressor_are_noted_only_above_the_measured_range
    assert_empty HostLoad.notes(limits, IDLE_WITH_OLD_SWAP), "1193 MiB and 4% are inside the measured range"
    heavy_history = IDLE_WITH_OLD_SWAP.merge("compressor_mib" => 4669, "swap_used_mib" => 6144.0)
    expected = ["swap in use 6144 MiB is above 1600 MiB", "memory compressor occupies 57% of memory, above 25%"]
    assert_equal expected, HostLoad.notes(limits, heavy_history)
    assert_equal expected, HostLoad.assess(sampler: -> { heavy_history })
    assert_equal [], HostLoad.assess(sampler: -> { IDLE_WITH_OLD_SWAP })
    assert_equal ["swap in use 1601 MiB is above 1600 MiB"], HostLoad.notes(limits, IDLE.merge("swap_used_mib" => 1601.0))
    assert_empty HostLoad.notes(limits, IDLE.merge("swap_used_mib" => 1600.0, "compressor_mib" => 2048))
    assert_equal ["memory compressor occupies 26% of memory, above 25%"], HostLoad.notes(limits, IDLE.merge("compressor_mib" => 2130))
  end

  def test_present_stress_and_old_swap_are_all_reported_together
    heavy_history = IDLE_WITH_OLD_SWAP.merge("compressor_mib" => 4669, "swap_used_mib" => 6144.0)
    STRESS.each do |change, expected|
      notes = HostLoad.assess(sampler: -> { heavy_history.merge(change) })
      assert_match(expected, notes.join("; "), change.inspect)
      assert_equal 3, notes.length, change.inspect
    end
  end

  def test_every_threshold_cites_the_readings_behind_it
    advisory = JSON.parse(File.read(HostLoad::POLICY)).fetch("advisory")
    rationale = advisory.fetch("rationale")
    (HostLoad::LIMITS + %w[scope]).each do |name|
      assert_operator rationale.fetch(name).length, :>, 30, name
    end
    assert_match(/removed all native host guards on 2026-11-22/, rationale.fetch("scope"))
    assert_match(/1193 MiB on an idle host with normal memory pressure/, rationale.fetch("warn_swap_used_mib"))
    # A note threshold sits above every reading taken while the host worked.
    assert_operator advisory.fetch("warn_swap_used_mib"), :>, 1551
    assert_operator advisory.fetch("warn_compressor_percent_of_memory"), :>, 100.0 * 1807 / 8192
    assert_operator advisory.fetch("warn_load_percent_of_cpus") * 8 / 100.0, :>, 4.96
    assert_operator advisory.fetch("warn_load_percent_of_cpus") * 8 / 100.0, :<, 6.11
    refute_includes HostLoad.limits.keys, "rationale"
  end

  def test_unreadable_telemetry_or_policy_is_a_note_never_a_refusal
    assert_empty HostLoad.assess(sampler: -> { IDLE })
    assert_equal ["host load inspection failed (RuntimeError: probe)"], HostLoad.assess(sampler: -> { raise "probe" })
    assert_match(/inspection failed/, HostLoad.assess(sampler: -> { IDLE }, policy: -> { raise KeyError, "limits" }).first)
  end

  def test_limits_require_every_non_negative_integer_and_a_compiler_list
    assert_equal (HostLoad::LIMITS + ["foreign_compilers"]).sort, limits.keys.sort
    assert_equal COMPILERS, limits.fetch("foreign_compilers")
    Dir.mktmpdir("host-load-") do |directory|
      path = File.join(directory, "policy.json")
      File.write(path, JSON.generate("version" => 1))
      assert_match(/Missing advisory/, assert_raises(RuntimeError) { HostLoad.limits(path) }.message)
      valid = limits
      { "warn_swap_used_mib" => -1, "warn_load_percent_of_cpus" => 0.75, "child_niceness" => nil,
        "warn_compressor_percent_of_memory" => 25.5, "foreign_compilers" => "cargo" }.each do |key, value|
        File.write(path, JSON.generate("advisory" => valid.merge(key => value)))
        assert_match(/Invalid advisory #{key}/, assert_raises(RuntimeError) { HostLoad.limits(path) }.message)
      end
    end
  end

  def test_capture_uses_a_fixed_locale_and_a_deadline
    assert_equal "C\n", HostLoad.capture("/bin/sh", "-c", "echo $LC_ALL")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(RuntimeError) { HostLoad.capture("/bin/sleep", "20", seconds: 0.2) }
    assert_match(/sleep telemetry deadline exceeded/, error.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 15, "the probe was not stopped at its deadline"
  end
end
