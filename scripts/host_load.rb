# frozen_string_literal: true

require "json"
require "open3"

# Read-only host telemetry, reported as information. Thresholds and the readings
# behind them live under "advisory" in config/mac-build-budget.json. Nothing
# here refuses, delays or stops a job: load, kernel memory pressure, thermal
# limits, a compiler outside the lease, swap and the compressor's size become
# notes in the log and the flight recorder (Pietro removed the host guards on
# 2026-11-22). Unreadable telemetry is also only a note.
module HostLoad
  POLICY = File.expand_path("../config/mac-build-budget.json", __dir__)
  MIB = 1024.0 * 1024
  SYSCTL = "/usr/sbin/sysctl"
  PMSET = "/usr/bin/pmset"
  PS = "/bin/ps"
  REQUIRED = %w[vm.loadavg vm.swapusage vm.compressor_bytes_used kern.memorystatus_vm_pressure_level
                hw.logicalcpu hw.memsize].freeze
  # Absent outside Intel XCPM hosts; recorded when present, never a limit (its scale is undocumented).
  OPTIONAL = %w[machdep.xcpm.cpu_thermal_level].freeze
  PRESSURE = { 1 => "normal", 2 => "warning", 4 => "critical" }.freeze
  # A step started from inside a build (an Xcode build phase, a compiler driver)
  # is part of that build, so the compilers that descend from the builds it runs
  # inside are not reported as foreign.
  ENCLOSING_BUILDS = %w[xcodebuild SWBBuildService XCBBuildService Xcode].freeze
  LIMITS = %w[warn_load_percent_of_cpus warn_swap_used_mib warn_compressor_percent_of_memory
              child_niceness].freeze

  # Every probe has a deadline and a fixed locale: stuck telemetry must not hang
  # a supervisor, and a comma decimal separator must not change the reading. A
  # probe that fails is an error, never an empty reading: an empty process list
  # would hide a running compiler.
  def self.capture(*argv, seconds: 4, tolerate_failure: false)
    Open3.popen3({ "LC_ALL" => "C", "LANG" => "C" }, *argv, pgroup: true) do |input, stdout, stderr, waiter|
      input.close
      readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
      name = File.basename(argv.first)
      raise "#{name} telemetry deadline exceeded" unless waiter.join(seconds)

      status = waiter.value
      raise "#{name} failed (#{status.exitstatus ? "exit #{status.exitstatus}" : "signal #{status.termsig}"})" unless status.success? || tolerate_failure

      readers.first.value
    ensure
      # Also reached when the reading thread is stopped: no probe outlives its reader.
      if waiter.alive?
        Process.kill("KILL", -waiter.pid) rescue Errno::ESRCH
        waiter.join
        readers&.each(&:join)
      end
    end
  end

  def self.limits(path = POLICY)
    value = JSON.parse(File.read(path))["advisory"]
    raise "Missing advisory limits in #{File.basename(path)}" unless value.is_a?(Hash)
    LIMITS.each { |key| raise "Invalid advisory #{key}" unless value[key].is_a?(Integer) && !value[key].negative? }
    names = value["foreign_compilers"]
    raise "Invalid advisory foreign_compilers" unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) && !name.empty? }
    # The "rationale" texts beside the thresholds are for people.
    value.slice(*LIMITS, "foreign_compilers")
  end

  def self.number(text)
    Float(text.to_s.tr(",", "."))
  end

  # Executable names sorted by CPU, with each process's parent. Arguments are
  # never read or recorded. The list always contains this process, so an empty
  # or foreign answer is rejected instead of trusted.
  def self.processes(capture, current_pid)
    rows = capture.call(PS, "-A", "-r", "-o", "pcpu=", "-o", "pid=", "-o", "ppid=", "-o", "comm=").lines.filter_map do |line|
      cpu, pid, parent, command = line.strip.split(/\s+/, 4)
      [cpu, pid, parent, File.basename(command)] if command
    end
    raise "Invalid process telemetry" unless rows.any? { |_, pid, _, _| pid == current_pid }

    rows
  end

  def self.sample(capture: method(:capture), compilers: limits.fetch("foreign_compilers"), current_pid: Process.pid)
    # Only an OPTIONAL name may be unknown to sysctl, which then exits non-zero.
    text = capture.call(SYSCTL, *REQUIRED) + capture.call(SYSCTL, *OPTIONAL, tolerate_failure: true)
    values = text.lines.filter_map do |line|
      name, value = line.chomp.split(": ", 2)
      [name, value] if value
    end.to_h
    missing = REQUIRED - values.keys
    raise "Missing #{missing.join(', ')} telemetry" unless missing.empty?

    load = values["vm.loadavg"].scan(/\d+(?:[.,]\d+)?/).first(3).map { |part| number(part) }
    swap = values["vm.swapusage"].scan(/(total|used) = (\d+(?:[.,]\d+)?)M/).to_h
    raise "Invalid load average telemetry" unless load.length == 3
    raise "Invalid swap telemetry" unless swap.key?("total") && swap.key?("used")
    pressure = Integer(values["kern.memorystatus_vm_pressure_level"])
    raise "Invalid memory pressure telemetry" unless PRESSURE.key?(pressure)

    thermal = capture.call(PMSET, "-g", "therm")
    raise "Invalid thermal telemetry" if thermal.strip.empty?
    limit = ->(name) { thermal[/#{name}\s*=\s*(\d+)/, 1]&.to_i }
    current_pid = current_pid.to_s
    rows = processes(capture, current_pid)
    parents = rows.to_h { |_, pid, parent, _| [pid, parent] }
    names = rows.to_h { |_, pid, _, name| [pid, name] }
    lineage = lambda do |pid|
      chain = [parents[pid]]
      chain << parents[chain.last] while chain.last && chain.length < 64
      chain.compact
    end
    # Nearest first: every build this process runs inside.
    enclosing = lineage.call(current_pid).select { |pid| ENCLOSING_BUILDS.include?(names[pid]) || compilers.include?(names[pid]) }
    running = rows.select { |_, _, _, name| compilers.include?(name) }
    own = running.select { |_, pid, _, _| enclosing.include?(pid) || !(lineage.call(pid) & enclosing).empty? }
    label = ->(list) { list.map { |_, pid, _, name| "#{name} #{pid}" } }
    level = values["machdep.xcpm.cpu_thermal_level"]
    { "load" => load, "cpus" => Integer(values["hw.logicalcpu"]),
      "memory_mib" => (Integer(values["hw.memsize"]) / MIB).round,
      "swap_used_mib" => number(swap["used"]), "swap_total_mib" => number(swap["total"]),
      "compressor_mib" => (Integer(values["vm.compressor_bytes_used"]) / MIB).round,
      "pressure" => pressure,
      # pmset prints these only after the first CPU power notification of a boot.
      "cpu_speed_limit" => limit.call("CPU_Speed_Limit"), "cpu_scheduler_limit" => limit.call("CPU_Scheduler_Limit"),
      "cpu_available" => limit.call("CPU_Available_CPUs"),
      "thermal_level" => (Integer(level) if level.to_s.match?(/\A\d+\z/)),
      "top" => rows.first(3).map { |cpu, pid, _, name| "#{cpu} #{pid} #{name}" },
      "compilers" => label.call(running), "own_compilers" => label.call(own),
      "enclosing_build" => ("#{names[enclosing.first]} #{enclosing.first}" unless enclosing.empty?) }
  end

  # Readings worth a look, as sentences. None of them refuses a job. Swap in use
  # and the compressor's size record earlier pressure: swap read 1193 MiB on an
  # idle host whose memory pressure was normal.
  def self.notes(limits, sample)
    found = []
    cpus = sample.fetch("cpus")
    ceiling = limits.fetch("warn_load_percent_of_cpus") * cpus / 100.0
    current = sample.fetch("load").first
    if current > ceiling
      found << format("1-minute load average %.2f exceeds %.2f (%d%% of %d CPUs)",
                      current, ceiling, limits.fetch("warn_load_percent_of_cpus"), cpus)
    end
    pressure = sample.fetch("pressure")
    found << "memory pressure is #{PRESSURE.fetch(pressure)}" unless pressure == 1
    { "cpu_speed_limit" => "CPU_Speed_Limit", "cpu_scheduler_limit" => "CPU_Scheduler_Limit" }.each do |key, name|
      value = sample[key]
      found << "#{name} is #{value} (thermal throttling)" if value && value < 100
    end
    available = sample["cpu_available"]
    found << "only #{available} of #{cpus} CPUs available (thermal throttling)" if available && available < cpus
    # Compilers this lease does not coordinate: a package-manager source build,
    # an IDE, another tool. Only the compilers of the build this step runs
    # inside are its own.
    foreign = Array(sample["compilers"]) - Array(sample["own_compilers"])
    found << "a compiler is already running (#{foreign.first(4).join(', ')})" unless foreign.empty?
    swap = sample.fetch("swap_used_mib")
    if swap > limits.fetch("warn_swap_used_mib")
      found << format("swap in use %.0f MiB is above %d MiB", swap, limits.fetch("warn_swap_used_mib"))
    end
    compressor = 100.0 * sample.fetch("compressor_mib") / sample.fetch("memory_mib")
    if compressor > limits.fetch("warn_compressor_percent_of_memory")
      found << format("memory compressor occupies %.0f%% of memory, above %d%%",
                      compressor, limits.fetch("warn_compressor_percent_of_memory"))
    end
    found
  end

  # One reading judged once. Unreadable telemetry is a note, never a refusal.
  def self.assess(sampler: method(:sample), policy: method(:limits))
    limits = policy.call
    notes(limits, sampler.call)
  rescue StandardError => error
    ["host load inspection failed (#{error.class}: #{error.message})"]
  end
end
