# frozen_string_literal: true
require "minitest/autorun"
require "json"
require "tmpdir"
require "open3"
require "rbconfig"
require "time"
require "timeout"
require_relative "native_job"

# Drives the real supervisor on a fixture lease with host services switched on
# and fixture telemetry, so no host load, lease or evidence directory is touched.
class NativeJobAdmissionTest < Minitest::Test
  SCRIPT = File.expand_path("native_job.rb", __dir__)
  RUBY = RbConfig.ruby
  IDLE = { "load" => [2.56, 3.25, 9.03], "cpus" => 8, "memory_mib" => 8192, "swap_used_mib" => 331.25,
           "swap_total_mib" => 2048.0, "compressor_mib" => 782, "pressure" => 1, "cpu_speed_limit" => 100,
           "cpu_scheduler_limit" => 100, "cpu_available" => 8, "thermal_level" => 52,
           "top" => ["98.2 47168 swift-frontend"], "compilers" => [], "enclosing_build" => nil }.freeze
  LOADED = IDLE.merge("load" => [7.12, 4.46, 8.85], "cpu_speed_limit" => 81).freeze
  # One serial build measured a load of 4.24: only its process name tells it from an idle host.
  FOREIGN_BUILD = IDLE.merge("load" => [4.24, 4.56, 5.86], "compilers" => ["cargo 61001", "rustc 61020"]).freeze
  LIMITS = { "max_load_percent_of_cpus" => 75, "max_swap_used_mib" => 1024, "max_compressor_percent_of_memory" => 50,
             "recheck_seconds" => 1, "child_niceness" => 10, "foreign_compilers" => %w[cargo rustc] }.freeze
  FLIGHT = { "interval_seconds" => 1, "max_file_bytes" => 65_536, "generations" => 1 }.freeze
  FLIGHT_DIR_ENV = "EPUB_NATIVE_FLIGHT_DIR"
  STUBS = <<~'RUBY'
    NativeJob.define_singleton_method(:host_services?) { |_path, **| true }
    NativeJob.host_services
    NativeJob.send(:remove_const, :LEASE_RETRY_SECONDS)
    NativeJob.const_set(:LEASE_RETRY_SECONDS, 1)
    HostLoad.define_singleton_method(:limits) { |*| JSON.parse(ENV.fetch("FIXTURE_LIMITS")) }
    HostLoad.define_singleton_method(:sample) do |**|
      path = ENV.fetch("FIXTURE_SAMPLES")
      queue = JSON.parse(File.read(path))
      current = queue.length > 1 ? queue.shift : queue.first
      File.write(path, JSON.generate(queue))
      current
    end
    NativeFlightRecorder.define_singleton_method(:limits) { |*| JSON.parse(ENV.fetch("FIXTURE_FLIGHT")) }
    NativeFlightRecorder.define_singleton_method(:host) { |**| { "startup_power_events" => "4f00000000000000" } }
  RUBY

  def setup
    @dir = Dir.mktmpdir("native-admission-")
    @lock = File.join(@dir, "lease")
    @marker = File.join(@dir, "child")
    @samples = File.join(@dir, "samples.json")
    @flight = File.join(@dir, "flight")
    # The compiler preflight and storage floor read fixture commands, as in test_native_job.rb.
    write_command("xcrun", %(#!/bin/bash\nprintf '{"devices":{"test":[{"state":"%s"}]}}\\n' "${FAKE_STATE:-Shutdown}"\n))
    write_command("pgrep", "#!/bin/bash\nexit 1\n")
    write_command("df", "#!/bin/bash\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\nfixture 41943040 0 31457280 0%% /\\n'\n")
    @env = { "PATH" => "#{@dir}:#{ENV.fetch('PATH')}", "FAKE_STATE" => nil,
             "FIXTURE_LIMITS" => JSON.generate(LIMITS), "FIXTURE_FLIGHT" => JSON.generate(FLIGHT), "FIXTURE_SAMPLES" => @samples,
             FLIGHT_DIR_ENV => @flight, NativeJob::FD_ENV => nil, NativeJob::PATH_ENV => nil, NativeJob::WAIT_ENV => nil,
             "GITHUB_ACTIONS" => nil, "RUNNER_ENVIRONMENT" => nil, "ImageOS" => nil }
    samples(IDLE)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_command(name, body)
    File.write(File.join(@dir, name), body)
    File.chmod(0o755, File.join(@dir, name))
  end

  def samples(*queue, path: @samples)
    File.write(path, JSON.generate(queue))
  end

  def supervisor(*arguments)
    [RUBY, "-r", SCRIPT, "-e", "#{STUBS}\nexit NativeJob.main(ARGV)", "--", "--lock-path", @lock, *arguments]
  end

  def job(*arguments, phase: "build", child: nil, env: {})
    child ||= [RUBY, "-e", "File.write(ARGV[0], File.read(ENV.fetch('EPUB_NATIVE_LEASE_PATH')))", @marker]
    Open3.capture3(@env.merge(env), *supervisor(*arguments, phase, "--", *child))
  end

  def wait_for(path)
    Timeout.timeout(10) { sleep 0.01 until File.size?(path) }
  end

  def assert_released
    File.open(@lock, "a+") { |file| assert file.flock(File::LOCK_EX | File::LOCK_NB), "lease remained held" }
    assert_equal "", File.read(@lock), "a released lease names no holder"
  end

  def holding(seconds = 30)
    ready = File.join(@dir, "ready")
    pid = Process.spawn(@env, *supervisor("build", "--", RUBY, "-e", "File.write(ARGV[0], 'ready'); sleep #{seconds}", ready),
                        out: File::NULL, err: File::NULL)
    wait_for(ready)
    yield pid
  ensure
    if pid
      Process.kill("TERM", pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
  end

  def test_loaded_host_refuses_before_any_child_and_releases_the_lease
    samples(LOADED)
    %w[build heavy].each do |phase|
      _, error, status = job(phase: phase)
      assert_equal 75, status.exitstatus, error
      assert_match(/Heavy job refused.*load average 7\.12 exceeds 6\.00.*CPU_Speed_Limit is 81/, error)
      refute File.exist?(@marker), phase
      refute Dir.exist?(@flight), "a refused job records nothing"
      assert_released
    end
  end

  def test_a_package_manager_or_ide_compile_outside_the_lease_is_refused_and_can_be_waited_for
    samples(FOREIGN_BUILD)
    _, error, status = job(phase: "heavy")
    assert_equal 75, status.exitstatus, error
    assert_match(/Heavy job refused.*a compiler is already running \(cargo 61001, rustc 61020\)/, error)
    refute File.exist?(@marker)
    samples(FOREIGN_BUILD, IDLE)
    _, error, status = job("--wait", "20")
    assert status.success?, error
    assert_equal 1, error.scan("Rechecking in 1 s").length, error
    assert File.exist?(@marker)
    assert_released
  end

  def test_admitted_job_publishes_its_holder_while_running_and_clears_it
    _, error, status = job
    assert status.success?, error
    record = JSON.parse(File.read(@marker))
    assert_equal %w[build running], record.values_at("phase", "state")
    assert_equal File.expand_path("..", __dir__), record["worktree"]
    assert_includes record["command"], "File.write"
    assert_operator record["pid"], :>, 1
    assert_in_delta Time.now.to_f, Time.iso8601(record["started"]).to_f, 60
    assert_released
  end

  def test_busy_lease_names_the_holder_and_wait_queues_for_it
    holding(2) do |pid|
      _, error, status = job
      assert_equal 75, status.exitstatus, error
      assert_match(/Another native\/heavy job is active \(pid #{pid}, build running since .*sleep 2/, error)
      refute File.exist?(@marker)
      _, error, status = job("--wait", "20")
      assert status.success?, error
      assert_match(/retrying in 1 s/, error)
      assert File.exist?(@marker)
    end
    assert_released
  end

  def test_wait_keeps_the_lease_until_the_host_is_admitted
    samples(LOADED, LOADED, IDLE)
    _, error, status = job
    assert_equal 75, status.exitstatus, "without --wait the first refusal is final: #{error}"
    samples(LOADED, LOADED, IDLE)
    _, error, status = job("--wait", "20")
    assert status.success?, error
    assert_equal 2, error.scan("Rechecking in 1 s").length, error
    assert_equal "running", JSON.parse(File.read(@marker))["state"]
    File.delete(@marker)
    samples(LOADED)
    _, error, status = job(phase: "heavy", env: { NativeJob::WAIT_ENV => "2" })
    assert_equal 75, status.exitstatus, error
    assert_match(/Rechecking/, error)
    refute File.exist?(@marker)
    assert_released
  end

  def test_child_runs_at_lower_priority_and_never_raises_it
    current = Process.getpriority(Process::PRIO_PROCESS, 0)
    _, error, status = job(child: [RUBY, "-e", "sleep 0.3; File.write(ARGV[0], Process.getpriority(Process::PRIO_PROCESS, 0))", @marker])
    assert status.success?, error
    assert_equal [LIMITS.fetch("child_niceness"), current].max, Integer(File.read(@marker))
    assert_equal current, Process.getpriority(Process::PRIO_PROCESS, 0)
  end

  def test_flight_recorder_writes_only_while_the_job_runs
    _, error, status = job(child: [RUBY, "-e", "sleep 2.6; exit 17"])
    assert_equal 17, status.exitstatus, error
    events = File.readlines(File.join(@flight, "flight.jsonl"), chomp: true).map { |line| JSON.parse(line) }
    kinds = events.map { |event| event["event"] }
    assert_equal %w[start end], [kinds.first, kinds.last]
    assert_operator kinds.count("sample"), :>=, 2, kinds.inspect
    assert_empty kinds - %w[start sample end]
    assert_equal 17, events.last["exit_status"]
    assert_equal "4f00000000000000", events.first["startup_power_events"]
    events.each do |event|
      assert_equal IDLE["load"], event["load"]
      assert_equal ["98.2 47168 swift-frontend"], event["top"]
      assert_equal "build", event.dig("holder", "phase")
      assert_includes event.dig("holder", "command"), "sleep 2.6"
    end
    assert_released
  end

  def test_status_shows_the_holder_and_the_admission_verdict
    output, error, status = Open3.capture3(@env, *supervisor("status"))
    assert status.success?, error
    report = JSON.parse(output)
    assert_equal({ "path" => @lock, "held" => false, "holder" => nil }, report["lease"])
    assert_nil report.dig("admission", "refusal")
    assert_equal File.join(@flight, "flight.jsonl"), report["flight_recorder"]
    refute File.exist?(@lock), "status never creates the lease"
    # The holder keeps reading its own queue; status reads a loaded host from another one.
    loaded = File.join(@dir, "loaded.json")
    samples(LOADED, path: loaded)
    holding do |pid|
      report = JSON.parse(Open3.capture3(@env.merge("FIXTURE_SAMPLES" => loaded), *supervisor("status")).first)
      assert_equal [true, pid, "running"], [report.dig("lease", "held"), report.dig("lease", "holder", "pid"), report.dig("lease", "holder", "state")]
      assert_match(/load average 7\.12/, report.dig("admission", "refusal"))
      assert_equal LOADED["load"], report.dig("admission", "sample", "load")
    end
  end

  def test_lease_file_replaced_during_acquisition_is_refused
    File.write(@lock, "")
    decoy = File.join(@dir, "decoy")
    File.write(decoy, "")
    swap = "real = File.method(:stat); File.define_singleton_method(:stat) { |path| real.call(path == ENV.fetch('FIXTURE_LOCK') ? ENV.fetch('FIXTURE_DECOY') : path) }"
    command = [RUBY, "-r", SCRIPT, "-e", "#{swap}\nexit NativeJob.main(ARGV)", "--", "--lock-path", @lock, "build", "--", RUBY, "-e", "File.write(ARGV[0], 'ran')", @marker]
    _, error, status = Open3.capture3(@env.merge("FIXTURE_LOCK" => @lock, "FIXTURE_DECOY" => decoy), *command)
    assert_equal 75, status.exitstatus, error
    assert_match(/lease file changed during acquisition/, error)
    refute File.exist?(@marker)
  end

  def test_full_host_suite_runs_under_the_lease_without_receiving_it
    runner = File.join(@dir, "runner.rb")
    File.write(runner, <<~RUBY)
      require #{SCRIPT.inspect}
      #{STUBS}
      NativeJob.heavy_entrypoint(__FILE__, ARGV, path: #{@lock.inspect})
      holder = NativeJob.holder(#{@lock.inspect})
      File.write(ARGV[0], JSON.generate("lease_env" => ENV.values_at(NativeJob::FD_ENV, NativeJob::PATH_ENV).compact,
                                        "held" => NativeJob.held?(#{@lock.inspect}), "phase" => holder && holder["phase"],
                                        "supervisor_is_parent" => holder && holder["pid"] == Process.ppid))
      exit 23
    RUBY
    _, error, status = Open3.capture3(@env, RUBY, runner, @marker)
    assert_equal 23, status.exitstatus, error
    assert_equal({ "lease_env" => [], "held" => true, "phase" => "heavy", "supervisor_is_parent" => true }, JSON.parse(File.read(@marker)))
    assert_released
    File.delete(@marker)
    samples(LOADED)
    _, error, status = Open3.capture3(@env, RUBY, runner, @marker)
    assert_equal 75, status.exitstatus, error
    assert_match(/Heavy job refused/, error)
    refute File.exist?(@marker)
  end

  def test_heavy_phase_skips_only_the_compiler_preflight
    child = [RUBY, "-e", "File.write(ARGV[0], ENV.fetch('CARGO_BUILD_JOBS'))", @marker]
    _, error, status = job(phase: "heavy", child: child, env: { "FAKE_STATE" => "Booted" })
    assert status.success?, error
    assert_equal "1", File.read(@marker)
    if RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
      File.delete(@marker)
      _, error, status = job(child: child, env: { "FAKE_STATE" => "Booted" })
      assert_equal 75, status.exitstatus, error
      assert_match(/Shut down all Simulators/, error)
      refute File.exist?(@marker)
    end
    assert_released
  end

  def test_host_services_belong_to_the_real_host_lease_only
    assert_equal NativeJob::HOST_LEASE, File.expand_path(NativeJob::LOCK_PATH)
    assert_equal !NativeJob.hosted_runner?, NativeJob.host_services?(NativeJob::LOCK_PATH, host: "x86_64-darwin24")
    refute NativeJob.host_services?(NativeJob::LOCK_PATH, host: "x86_64-linux")
    refute NativeJob.host_services?(@lock, host: "x86_64-darwin24"), "a fixture lease never reads host load"
    refute NativeJob.host_services?("/var/tmp/epub2mp3.heavy-job.lock", host: "x86_64-darwin24")
    refute Object.const_defined?(:HostLoad), "host modules load only for the host lease"
  end
end
