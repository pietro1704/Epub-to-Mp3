# frozen_string_literal: true
require "minitest/autorun"
require_relative "native_job_host_fixture"

# Who holds the lease, for how long, and what the record says about it.
class NativeLeaseHoldersTest < Minitest::Test
  include NativeJobHostFixture

  WRAPPER = File.expand_path("without_native_lease.rb", __dir__)
  WORKTREE = Regexp.escape(File.basename(File.expand_path("..", __dir__))[/\A[\w.:@+-]{1,80}\z/] || "unnamed")
  # A stand-in for a browser: its own process group and output, outliving the job that started it.
  BROWSER = "pid = Process.spawn(RbConfig.ruby, '-e', 'sleep 600', pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL); " \
            "File.write(ARGV[0], pid)"
  UNLISTABLE = "#{STUBS}\nNativeJob.define_singleton_method(:lease_holders) { |_path| raise 'lsof telemetry deadline exceeded' }"

  def status_report(env: {}, stubs: STUBS)
    output, error, status = finished(*supervisor("status", stubs: stubs), env: env)
    assert status.success?, error
    JSON.parse(output)
  end

  def test_a_running_job_publishes_its_holder_while_running_and_clears_it
    reader = "File.write(ARGV[0], JSON.generate('record' => JSON.parse(File.read(ENV.fetch('EPUB_NATIVE_LEASE_PATH'))), 'pid' => Process.pid))"
    _, error, status = job(child: [RUBY, "-rjson", "-e", reader, @marker], env: { "MISE_TASK_NAME" => "mac:test:local" })
    assert status.success?, error
    seen = JSON.parse(File.read(@marker))
    record = seen.fetch("record")
    assert_equal ["build", "running", PROGRAM, "mac:test:local"], record.values_at("phase", "state", "program", "task")
    assert_match(/\A#{WORKTREE}\z/, record["worktree"])
    assert_equal seen.fetch("pid"), record["child"], "the record names the job's process group"
    assert_operator record["pid"], :>, 1
    assert_in_delta Time.now.to_f, Time.iso8601(record["started"]).to_f, 3600
    assert_equal %w[child phase pid program session started state task worktree], record.keys.sort
    assert_released
  end

  def test_busy_lease_names_the_holder_and_wait_queues_for_it
    holding(env: { "MISE_TASK_NAME" => "ios:device:test" }) do |pid, child, release|
      _, error, status = job
      assert_equal 75, status.exitstatus, error
      assert_match(/Another native\/heavy job is active \(pid #{pid}, build running since \S+, #{WORKTREE}: #{Regexp.escape(PROGRAM)} in ios:device:test; lease file open in /, error)
      assert_match(/#{listed(child)}/, error, "the job's own process keeps the lease file open")
      refute File.exist?(@marker)
      waiter, log = background_job("--wait", "600")
      wait_until { said?(log, "retrying in 1 s") }
      release.call
      assert exit_status(waiter).success?, File.read(log)
      assert File.exist?(@marker)
    end
    assert_released
  end

  def test_a_waiting_job_lists_the_processes_on_its_first_and_final_refusal_only
    holding do |_, child|
      _, error, status = job("--wait", "3")
      assert_equal 75, status.exitstatus, error
      refusals = error.lines(chomp: true).grep(/Another native\/heavy job is active/)
      retries = refusals.grep(/; retrying in \d+ s\z/)
      assert_operator retries.length, :>=, 1, error
      assert_equal retries, refusals[0..-2], "every refusal but the last announces a retry"
      assert_match(/lease file open in .*#{listed(child)}/, retries.first)
      retries.drop(1).each { |line| refute_match(/lease file open in/, line, "a retry must not scan the process table again") }
      assert_match(/lease file open in .*#{listed(child)}/, refusals.last)
    end
  end

  def test_status_shows_the_holder_and_the_host_notes_without_locking
    never_locks = "#{STUBS}\nFile.class_eval { def flock(*) = raise('status must not take the lock') }"
    report = status_report(stubs: never_locks)
    assert_equal({ "path" => @lock, "held" => false, "holder" => nil, "open_in" => [] }, report["lease"])
    assert_equal [], report.dig("host", "notes")
    refute report.key?("admission"), "there is no admission verdict any more"
    samples(HEAVY_HISTORY)
    assert_equal 2, status_report.dig("host", "notes").length
    samples(IDLE)
    assert_equal File.join(@flight, "flight.jsonl"), report["flight_recorder"]
    refute File.exist?(@lock), "status never creates the lease"
    # The holder keeps reading its own queue; status reads a loaded host from another one.
    loaded = File.join(@dir, "loaded.json")
    samples(LOADED, path: loaded)
    holding do |pid, child|
      report = status_report(env: { "FIXTURE_SAMPLES" => loaded }, stubs: never_locks)
      assert_equal [true, pid, child, "running"],
                   [report.dig("lease", "held"), *report.dig("lease", "holder").values_at("pid", "child", "state")]
      assert_includes report.dig("lease", "open_in"), "#{child} #{LISTED}"
      assert_match(/load average 7\.12/, report.dig("host", "notes").join(" "))
      assert_equal LOADED["load"], report.dig("host", "sample", "load")
    end
  end

  def test_processes_that_cannot_be_listed_are_reported_as_unknown_never_as_nobody
    File.write(@lock, "")
    lease = status_report(stubs: UNLISTABLE).fetch("lease")
    assert_equal [nil, nil, "RuntimeError: lsof telemetry deadline exceeded"], lease.values_at("held", "open_in", "open_in_error"),
                 "with no record and no listing, whether the lease is held is unknown"
    holding do |pid|
      lease = status_report(stubs: UNLISTABLE).fetch("lease")
      assert_equal [true, pid, nil], [lease["held"], lease.dig("holder", "pid"), lease["open_in"]]
      _, error, status = finished(*supervisor("build", "--", *record_reader, stubs: UNLISTABLE))
      assert_equal 75, status.exitstatus, error
      assert_match(/is active \(pid #{pid}, .*; the processes that keep the lease file open could not be listed \(RuntimeError: lsof telemetry deadline exceeded\)\)/, error)
    end
  end

  # The holder and every status call share the fixture's sample queue; a truncating write let one see it empty.
  def test_concurrent_host_samples_never_find_the_queue_empty
    samples({ "a" => 1 }, { "a" => 2 })
    body = "#{STUBS}\n400.times { HostLoad.sample }"
    pids = Array.new(3) { start(RUBY, "-r", SCRIPT, "-e", body, err: fresh("err")) }
    pids.each { |pid| assert exit_status(pid).success?, "a sample read found the queue empty or partial" }
  end

  def test_the_linux_listing_reads_one_link_per_open_descriptor
    NativeJob.host_services
    File.write(@lock, "")
    other = File.join(@dir, "other")
    File.write(other, "")
    holder = start(RUBY, "-e", until_file(0), File.join(@dir, "never"))
    table = File.join(@dir, "proc")
    # The holder twice, this process, another file, a link to nothing and a name that is not a process ID.
    { "self/fd" => {}, "#{holder}/fd" => { "0" => File::NULL, "9" => @lock, "12" => @lock, "13" => File.join(@dir, "gone") },
      "#{Process.pid}/fd" => { "9" => @lock }, "77777777/fd" => { "3" => other }, "12abc/fd" => { "9" => @lock } }.each do |directory, links|
      FileUtils.mkdir_p(File.join(table, directory))
      links.each { |name, target| File.symlink(target, File.join(table, directory, name)) }
    end
    assert_equal ["#{holder} #{LISTED}"], NativeJob.lease_holders(@lock, proc_root: table)
    File.delete(File.join(table, holder.to_s, "fd", "9"), File.join(table, holder.to_s, "fd", "12"))
    assert_empty NativeJob.lease_holders(@lock, proc_root: table)
  end

  def test_lease_file_replaced_during_acquisition_is_refused
    File.write(@lock, "")
    decoy = File.join(@dir, "decoy")
    File.write(decoy, "")
    swap = "real = File.method(:stat); File.define_singleton_method(:stat) { |path| real.call(path == ENV.fetch('FIXTURE_LOCK') ? ENV.fetch('FIXTURE_DECOY') : path) }"
    command = [RUBY, "-r", SCRIPT, "-e", "#{swap}\nexit NativeJob.main(ARGV)", "--", "--lock-path", @lock, "build", "--", RUBY, "-e", "File.write(ARGV[0], 'ran')", @marker]
    _, error, status = finished(*command, env: { "FIXTURE_LOCK" => @lock, "FIXTURE_DECOY" => decoy })
    assert_equal 75, status.exitstatus, error
    assert_match(/lease file changed during acquisition/, error)
    refute File.exist?(@marker)
  end

  def test_full_host_suite_runs_under_the_lease_and_sees_no_lease_variable
    runner = suite_runner(<<~'RUBY')
      holder = NativeJob.holder(LOCK)
      descriptor = (IO.for_fd(NativeJob::CHILD_FD, autoclose: false).stat.ino == File.stat(LOCK).ino rescue false)
      File.write(ARGV[0], JSON.generate("lease_env" => ENV.values_at(NativeJob::FD_ENV, NativeJob::PATH_ENV).compact,
                                        "keeps_lease_description" => descriptor, "phase" => holder && holder["phase"],
                                        "is_the_job" => holder && holder["child"] == Process.pid))
      exit 23
    RUBY
    _, error, status = finished(RUBY, runner, @marker)
    assert_equal 23, status.exitstatus, error
    assert_equal({ "lease_env" => [], "keeps_lease_description" => true, "phase" => "heavy", "is_the_job" => true },
                 JSON.parse(File.read(@marker)))
    assert_released
    File.delete(@marker)
    samples(LOADED)
    _, error, status = finished(RUBY, runner, @marker)
    assert_equal 23, status.exitstatus, "a loaded host never refuses the suite: #{error}"
    assert_match(/advisory, not a refusal/, error)
    assert File.exist?(@marker)
  end

  def test_a_suite_started_through_a_shell_inside_the_heavy_job_is_not_refused
    runner = suite_runner(<<~'RUBY')
      if ARGV[1] == "inner"
        File.write(ARGV[0], JSON.generate("lease_env" => ENV.values_at(NativeJob::FD_ENV, NativeJob::PATH_ENV).compact))
        exit 0
      end
      exit(system("/bin/sh", "-c", 'true; "$0" "$1" "$2" inner', RbConfig.ruby, __FILE__, ARGV[0]) ? 0 : 31)
    RUBY
    _, error, status = finished(RUBY, runner, @marker)
    assert status.success?, "the nested suite was refused: #{error}"
    assert_equal({ "lease_env" => [] }, JSON.parse(File.read(@marker)))
    assert_released
  end

  def test_a_descriptor_that_only_points_at_the_lease_file_is_not_a_lease
    runner = suite_runner(<<~'RUBY')
      File.write(ARGV[0], JSON.generate("phase" => NativeJob.holder(LOCK)&.fetch("phase")))
    RUBY
    File.write(@lock, "")
    # Nobody holds the lease: the suite must take it and be supervised, not trust the number.
    File.open(@lock) do |stray|
      _, error, status = finished(RUBY, runner, @marker, descriptors: { NativeJob::CHILD_FD => stray })
      assert status.success?, error
      assert_equal "heavy", JSON.parse(File.read(@marker))["phase"], "a stray descriptor 9 skipped the lease, admission and priority"
    end
    assert_released
  end

  def test_lease_outlives_a_killed_supervisor_for_as_long_as_its_load_runs
    pids = File.join(@dir, "pids")
    runner = suite_runner(<<~'RUBY')
      # A step in its own process group, as RunSteps starts every suite.
      step = Process.spawn(RbConfig.ruby, "-e", "sleep 600", pgroup: true)
      File.write(ARGV[0], JSON.generate("runner" => Process.pid, "step" => step))
      sleep 600
    RUBY
    supervisor = start(RUBY, runner, pids)
    wait_for(pids)
    load = JSON.parse(File.read(pids))
    @children.concat(load.values)
    Process.kill("KILL", supervisor)
    exit_status(supervisor)
    refute lease_free?, "a killed supervisor released the lease while its suite was still running"
    _, error, status = job
    assert_equal 75, status.exitstatus, error
    assert_match(/Another native\/heavy job is active \(pid #{supervisor}, heavy orphaned, supervisor gone/, error)
    assert_match(/lease file open in .*#{listed(load.fetch('runner'))}/, error)
    refute File.exist?(@marker), "a new heavy job started on top of the orphaned load"
    Process.kill("KILL", load.fetch("runner"))
    wait_until { gone?(load.fetch("runner")) }
    refute lease_free?, "the suite's own step still runs and must keep the lease"
    _, error, status = job
    assert_equal 75, status.exitstatus, error
    assert_match(/lease file open in #{listed(load.fetch('step'))}\)/, error, "the refusal names the one process that still holds the lease")
    Process.kill("KILL", load.fetch("step"))
    wait_until { lease_free? }
    _, error, status = job
    assert status.success?, error
  end

  def test_a_process_that_leaves_the_job_with_the_lease_is_named_and_one_started_without_it_never_holds_it
    escaped = File.join(@dir, "escaped")
    _, error, status = job(child: [RUBY, "-e", BROWSER, escaped])
    assert status.success?, error
    browser = Integer(File.read(escaped))
    @children << browser
    refute lease_free?, "this browser inherited the lease, so it holds it after the job ended"
    _, error, status = job
    assert_equal 75, status.exitstatus, error
    assert_match(/Another native\/heavy job is active \(no holder record[^;]*; lease file open in #{listed(browser)}\)/, error)
    lease = status_report.fetch("lease")
    assert_equal [true, nil, ["#{browser} #{LISTED}"]], lease.values_at("held", "holder", "open_in"),
                 "status must show a lease that only a left-behind process holds"
    Process.kill("KILL", browser)
    wait_until { lease_free? }

    File.delete(escaped)
    _, error, status = job(child: [RUBY, WRAPPER, RUBY, "-e", BROWSER, escaped])
    assert status.success?, error
    browser = Integer(File.read(escaped))
    @children << browser
    assert NativeJob.alive?(browser), "the browser is still running"
    assert_released
    assert_equal [false, []], status_report.fetch("lease").values_at("held", "open_in")
    _, error, status = job
    assert status.success?, "a browser started without the lease must not refuse the next job: #{error}"
  end

  def test_the_wrapper_withholds_only_the_lease_and_passes_everything_else_through
    probe = "print JSON.generate('env' => ENV.values_at('EPUB_NATIVE_LEASE_FD', 'EPUB_NATIVE_LEASE_PATH').compact, " \
            "'open' => [8, 9].map { |fd| (IO.for_fd(fd, autoclose: false).stat; true) rescue false }, 'argv' => ARGV)"
    File.write(@lock, "")
    other = File.join(@dir, "other")
    File.write(other, "")
    File.open(@lock) do |lease|
      File.open(other) do |unrelated|
        descriptors = { 8 => unrelated, 9 => lease }
        with_lease = { "EPUB_NATIVE_LEASE_FD" => "9", "EPUB_NATIVE_LEASE_PATH" => @lock }
        output, error, status = finished(RUBY, WRAPPER, RUBY, "-rjson", "-e", probe, "a b", "*", env: with_lease, descriptors: descriptors)
        assert status.success?, error
        assert_equal({ "env" => [], "open" => [true, false], "argv" => ["a b", "*"] }, JSON.parse(output))
        # A number that points at another file is not the lease and stays open.
        output, = finished(RUBY, WRAPPER, RUBY, "-rjson", "-e", probe, env: with_lease.merge("EPUB_NATIVE_LEASE_PATH" => other), descriptors: descriptors)
        assert_equal({ "env" => [], "open" => [true, true], "argv" => [] }, JSON.parse(output))
        output, error, status = finished(RUBY, WRAPPER, RUBY, "-e", "exit 7")
        assert_equal 7, status.exitstatus, "#{output}#{error}"
      end
    end
    _, error, status = finished(RUBY, WRAPPER)
    refute status.success?
    assert_match(/Usage: without_native_lease\.rb/, error)
  end

  def test_no_argument_or_absolute_path_reaches_the_lease_record_the_refusal_or_the_flight_log
    secrets = ["--authenticationKeyPath", "/Users/someone/keys/AuthKey_SECRET123.p8", "https://user:TOKEN456@example.invalid/x"]
    flight_log = File.join(@flight, "flight.jsonl")
    holding(arguments: secrets, env: { "MISE_TASK_NAME" => "ios:device:test", "CLAUDE_CODE_SESSION_ID" => "/Users/someone/session" }) do |_, _, release|
      record = File.read(@lock)
      _, refusal, status = job
      assert_equal 75, status.exitstatus, refusal
      wait_until { File.size?(flight_log) }
      release.call
      wait_until { lease_free? }
      { "lease record" => record, "refusal" => refusal, "flight log" => File.read(flight_log) }.each do |name, text|
        refute_empty text, name
        ["SECRET123", "TOKEN456", "authenticationKey", "example.invalid", "/Users/", "someone", Dir.home, @dir, "File.write"].each do |forbidden|
          refute_includes text, forbidden, "the #{name} must not carry #{forbidden}"
        end
      end
      assert_equal [PROGRAM, "ios:device:test", ""], JSON.parse(record).values_at("program", "task", "session")

    end
    assert_equal "600", format("%o", File.stat(@lock).mode & 0o777), "only the owner reads the lease record"
    assert_equal %w[700 600], [@flight, flight_log].map { |path| format("%o", File.stat(path).mode & 0o777) }
    File.chmod(0o644, @lock)
    _, error, status = job
    assert status.success?, error
    assert_equal "600", format("%o", File.stat(@lock).mode & 0o777), "a lease file left readable by an older checkout is tightened"
  end

  def test_a_reader_never_sees_an_empty_or_torn_holder_record_while_it_is_rewritten
    rewriting = <<~'RUBY'
      handle, = NativeJob.lease(ARGV[0])
      short = { "pid" => Process.pid, "state" => "running" }
      long = short.merge("state" => "waiting for admission", "session" => "x" * 400)
      NativeJob.publish(handle, long)
      reads = 0
      missing = 0
      # Keep both threads active in each batch without depending on how many
      # writes the scheduler allows before the reader finishes.
      read_batch_started = Queue.new
      write_batch_finished = Queue.new
      reader = Thread.new do
        30.times do
          read_batch_started << true
          100.times do
            missing += 1 unless NativeJob.holder(ARGV[0])&.fetch("pid") == Process.pid
            reads += 1
          end
          write_batch_finished.pop
        end
      end
      turn = 0
      30.times do
        read_batch_started.pop
        10.times { NativeJob.publish(handle, (turn += 1).even? ? short : long) }
        write_batch_finished << true
      end
      reader.value
      NativeJob.publish(handle, nil)
      print JSON.generate("reads" => reads, "rewrites" => turn, "missing" => missing, "left" => File.read(ARGV[0]))
    RUBY
    output, error, status = finished(RUBY, "-r", SCRIPT, "-e", rewriting, @lock)
    assert status.success?, error
    seen = JSON.parse(output)
    assert_equal [3000, 300], seen.values_at("reads", "rewrites")
    assert_equal [0, ""], seen.values_at("missing", "left"),
                 "#{seen['missing']} of #{seen['reads']} reads found no holder during #{seen['rewrites']} rewrites"
  end
end
