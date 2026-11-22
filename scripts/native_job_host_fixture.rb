# frozen_string_literal: true
require "json"
require "tmpdir"
require "open3"
require "rbconfig"
require "time"
require "timeout"
require "fileutils"
require_relative "native_job"

# Shared by the host-lease suites. It drives the real supervisor on a fixture
# lease with host services switched on and fixture telemetry, so no host load,
# lease or evidence directory is touched. Nothing here depends on how fast the
# host is: a test waits for what a process says or writes, never for a duration.
# A job writes to files, not pipes, so a process it leaves behind cannot keep a
# test waiting, and every stand-in process ends by itself.
module NativeJobHostFixture
  SCRIPT = File.expand_path("native_job.rb", __dir__)
  RUBY = RbConfig.ruby
  # What a holder record and a process list call this interpreter: "ruby" for a
  # mise installation, "ruby3.2" for a distribution package. Linux keeps at most
  # 15 characters of a process name.
  PROGRAM = File.basename(RUBY)
  LISTED = RUBY_PLATFORM.include?("linux") ? PROGRAM[0, 15] : PROGRAM
  IDLE = { "load" => [2.56, 3.25, 9.03], "cpus" => 8, "memory_mib" => 8192, "swap_used_mib" => 331.25,
           "swap_total_mib" => 2048.0, "compressor_mib" => 782, "pressure" => 1, "cpu_speed_limit" => 100,
           "cpu_scheduler_limit" => 100, "cpu_available" => 8, "thermal_level" => 52,
           "top" => ["98.2 47168 swift-frontend"], "compilers" => [], "own_compilers" => [], "enclosing_build" => nil }.freeze
  LOADED = IDLE.merge("load" => [7.12, 4.46, 8.85], "cpu_speed_limit" => 81).freeze
  # One serial build measured a load of 4.24: only its process name tells it from an idle host.
  FOREIGN_BUILD = IDLE.merge("load" => [4.24, 4.56, 5.86], "compilers" => ["cargo 61001", "rustc 61020"]).freeze
  # 00:32 BRT on 2026-11-20 (03:32 UTC): idle, normal memory pressure, 1193 MiB of swap left by earlier work.
  # The compressor at 57% of memory and swap beyond every reading are added to that host.
  OLD_SWAP = IDLE.merge("load" => [3.32, 3.77, 3.77], "swap_used_mib" => 1192.75, "compressor_mib" => 368).freeze
  HEAVY_HISTORY = OLD_SWAP.merge("swap_used_mib" => 6144.0, "compressor_mib" => 4669).freeze
  LIMITS = { "warn_load_percent_of_cpus" => 75, "warn_swap_used_mib" => 1600, "warn_compressor_percent_of_memory" => 25,
             "child_niceness" => 10,
             "foreign_compilers" => %w[cargo rustc] }.freeze
  FLIGHT = { "interval_seconds" => 1, "max_file_bytes" => 65_536, "generations" => 1 }.freeze
  FLIGHT_DIR_ENV = "EPUB_NATIVE_FLIGHT_DIR"
  # FIXTURE_FAST_SAMPLES readings answer at once (the start-up note); later ones take
  # FIXTURE_SAMPLE_DELAY seconds, like telemetry on a loaded host.
  STUBS = <<~'RUBY'
    NativeJob.define_singleton_method(:host_services?) { |_path, **| true }
    NativeJob.host_services
    { LEASE_RETRY_SECONDS: Integer(ENV.fetch("FIXTURE_LEASE_RETRY", "1")), NICE: ENV["FIXTURE_NICE"] }.each do |name, value|
      next unless value

      NativeJob.send(:remove_const, name) if NativeJob.const_defined?(name, false)
      NativeJob.const_set(name, value)
    end
    HostLoad.define_singleton_method(:limits) { |*| JSON.parse(ENV.fetch("FIXTURE_LIMITS")) }
    HostLoad.define_singleton_method(:sample) do |**|
      path = ENV.fetch("FIXTURE_SAMPLES")
      calls = File.exist?("#{path}.calls") ? Integer(File.read("#{path}.calls")) + 1 : 1
      File.write("#{path}.calls", calls)
      sleep Float(ENV.fetch("FIXTURE_SAMPLE_DELAY", "0")) if calls > Integer(ENV.fetch("FIXTURE_FAST_SAMPLES", "1000000"))
      queue = JSON.parse(File.read(path))
      current = queue.length > 1 ? queue.shift : queue.first
      File.write(path, JSON.generate(queue))
      current
    end
    NativeFlightRecorder.define_singleton_method(:limits) { |*| JSON.parse(ENV.fetch("FIXTURE_FLIGHT")) }
    NativeFlightRecorder.define_singleton_method(:host) { |**| { "startup_power_events" => "4f00000000000000" } }
  RUBY

  def setup
    @dir = File.realpath(Dir.mktmpdir("native-host-lease-"))
    @lock = File.join(@dir, "lease")
    @marker = File.join(@dir, "child")
    @samples = File.join(@dir, "samples.json")
    @flight = File.join(@dir, "flight")
    @children = []
    # The storage reading uses a fixture command, as in test_native_job.rb.
    write_command("df", "#!/bin/bash\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\nfixture 41943040 0 31457280 0%% /\\n'\n")
    @env = { "PATH" => "#{@dir}:#{ENV.fetch('PATH')}",
             "FIXTURE_LIMITS" => JSON.generate(LIMITS), "FIXTURE_FLIGHT" => JSON.generate(FLIGHT), "FIXTURE_SAMPLES" => @samples,
             "FIXTURE_LEASE_RETRY" => nil, "FIXTURE_NICE" => nil, "FIXTURE_SAMPLE_DELAY" => nil, "FIXTURE_FAST_SAMPLES" => nil,
             FLIGHT_DIR_ENV => @flight, NativeJob::FD_ENV => nil, NativeJob::PATH_ENV => nil, NativeJob::WAIT_ENV => nil,
             "MISE_TASK_NAME" => nil, "GITHUB_ACTIONS" => nil, "RUNNER_ENVIRONMENT" => nil, "ImageOS" => nil }
    # The session that runs this suite must not name itself in a fixture record.
    NativeJob::SESSION_KEYS.each_value { |key| @env[key] = nil }
    samples(IDLE)
  end

  def teardown
    @children.each do |pid|
      Process.kill("KILL", pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
    FileUtils.remove_entry(@dir)
  end

  def write_command(name, body)
    File.write(File.join(@dir, name), body)
    File.chmod(0o755, File.join(@dir, name))
  end

  def limits(changes)
    { "FIXTURE_LIMITS" => JSON.generate(LIMITS.merge(changes)) }
  end

  def samples(*queue, path: @samples)
    File.write(path, JSON.generate(queue))
    File.delete("#{path}.calls") if File.exist?("#{path}.calls")
  end

  def supervisor(*arguments, stubs: STUBS)
    [RUBY, "-r", SCRIPT, "-e", "#{stubs}\nexit NativeJob.main(ARGV)", "--", "--lock-path", @lock, *arguments]
  end

  # The default child copies the holder record it can read while it runs.
  def record_reader
    [RUBY, "-e", "File.write(ARGV[0], File.read(ENV.fetch('EPUB_NATIVE_LEASE_PATH')))", @marker]
  end

  # A path in the fixture directory that no earlier process of this test used.
  def fresh(name)
    File.join(@dir, "#{@sequence = @sequence.to_i + 1}-#{name}")
  end

  # Inside the heavy host-suite job this suite holds the host lease on
  # descriptor 9. No fixture process inherits it: one left behind by a killed
  # run would keep the host lease.
  def without_outer_lease
    IO.for_fd(NativeJob::CHILD_FD, autoclose: false).stat
    { NativeJob::CHILD_FD => :close }
  rescue StandardError
    {}
  end

  # Starts a fixture process that teardown stops if the test does not.
  def start(*command, env: {}, out: File::NULL, err: File::NULL, descriptors: {})
    options = { in: File::NULL, out: out, err: err }.merge(without_outer_lease).merge(descriptors)
    Process.spawn(@env.merge(env), *command, options).tap { |pid| @children << pid }
  end

  # Runs any command to its end and returns what it wrote and how it ended.
  def finished(*command, env: {}, descriptors: {})
    out = fresh("out")
    err = fresh("err")
    status = exit_status(start(*command, env: env, out: out, err: err, descriptors: descriptors))
    [File.read(out), File.read(err), status]
  end

  # `prefix` goes before the supervisor, for example a lower priority.
  def job(*arguments, phase: "build", child: record_reader, env: {}, prefix: [])
    finished(*prefix, *supervisor(*arguments, phase, "--", *child), env: env)
  end

  # A job in the background whose messages go to a file a test can wait on.
  def background_job(*arguments, child: record_reader, env: {})
    log = fresh("job.err")
    [start(*supervisor(*arguments, "build", "--", *child), env: env, err: log), log]
  end

  # Pattern source for one process in a list of lease holders.
  def listed(pid)
    "\\b#{pid} #{Regexp.escape(LISTED)}(?![\\w.])"
  end

  def said?(log, text)
    File.exist?(log) && File.read(log).include?(text)
  end

  def exit_status(pid)
    status = Timeout.timeout(120) { Process.waitpid2(pid).last }
    @children.delete(pid)
    status
  end

  def wait_for(path)
    Timeout.timeout(60) { sleep 0.01 until File.size?(path) }
  end

  def wait_until(seconds = 60)
    Timeout.timeout(seconds) { sleep 0.02 until yield }
  end

  # Dead for the lease's purposes: a process that was killed has closed its
  # descriptors even while it waits, as a zombie, for a parent to collect it.
  def gone?(pid)
    return true unless NativeJob.alive?(pid)

    Open3.capture2("ps", "-o", "stat=", "-p", pid.to_s).first.strip.start_with?("Z")
  end

  def lease_free?
    File.open(@lock, "a+") { |file| file.flock(File::LOCK_EX | File::LOCK_NB) != false }
  end

  def assert_released
    assert lease_free?, "lease remained held"
    assert_equal "", File.read(@lock), "a released lease names no holder"
  end

  # Ruby source for a stand-in that waits for a file, for at most ten minutes.
  def until_file(index)
    "limit = Time.now + 600; sleep 0.05 until File.exist?(ARGV[#{index}]) || Time.now > limit"
  end

  # A guarded job that holds the lease until the block ends or `release` is called.
  def holding(env: {}, arguments: [])
    ready = fresh("ready")
    release = fresh("release")
    child = [RUBY, "-e", "File.write(ARGV[0], Process.pid); #{until_file(1)}", ready, release, *arguments]
    pid = start(*supervisor("build", "--", *child), env: env)
    wait_for(ready)
    yield pid, Integer(File.read(ready)), -> { File.write(release, "") }
  ensure
    if pid && @children.include?(pid)
      Process.kill("TERM", pid) rescue Errno::ESRCH
      exit_status(pid) rescue nil
    end
  end

  # A stand-in for run_ci_contracts.rb: it re-runs itself under the heavy lease.
  def suite_runner(body)
    path = File.join(@dir, "runner.rb")
    File.write(path, <<~RUBY)
      require #{SCRIPT.inspect}
      #{STUBS}
      LOCK = #{@lock.inspect}
      NativeJob.heavy_entrypoint(__FILE__, ARGV, path: LOCK)
      #{body}
    RUBY
    path
  end
end
