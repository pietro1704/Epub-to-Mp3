# frozen_string_literal: true

require "json"
require "open3"

# Read-only host telemetry and the admission rule for one more heavy job.
# Limits live under "admission" in config/mac-build-budget.json; the measured
# values behind them are recorded in docs/agents/execution-policy.md. Admission
# reduces overlap with load this repository does not control. It is not a
# kernel-panic or CATERR prevention.
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
  # A guarded step started from inside a build (an Xcode build phase, a compiler
  # driver) is part of that build: the compilers and load are its own, and
  # refusing it would fail the build that asked for it.
  ENCLOSING_BUILDS = %w[xcodebuild SWBBuildService XCBBuildService Xcode].freeze
  LIMITS = %w[max_load_percent_of_cpus max_swap_used_mib max_compressor_percent_of_memory
              recheck_seconds child_niceness].freeze

  # Every probe has a deadline and a fixed locale: stuck telemetry must not hang
  # a supervisor, and a comma decimal separator must not change the reading.
  def self.capture(*argv, seconds: 4)
    Open3.popen3({ "LC_ALL" => "C", "LANG" => "C" }, *argv, pgroup: true) do |input, stdout, stderr, waiter|
      input.close
      readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
      unless waiter.join(seconds)
        Process.kill("KILL", -waiter.pid) rescue Errno::ESRCH
        waiter.join
        readers.each(&:join)
        raise "#{File.basename(argv.first)} telemetry deadline exceeded"
      end
      readers.map(&:value).first
    end
  end

  def self.limits(path = POLICY)
    value = JSON.parse(File.read(path))["admission"]
    raise "Missing admission limits in #{File.basename(path)}" unless value.is_a?(Hash)
    LIMITS.each { |key| raise "Invalid admission #{key}" unless value[key].is_a?(Integer) && !value[key].negative? }
    raise "Invalid admission recheck_seconds" unless value["recheck_seconds"].positive?
    names = value["foreign_compilers"]
    raise "Invalid admission foreign_compilers" unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) && !name.empty? }
    value
  end

  def self.number(text)
    Float(text.to_s.tr(",", "."))
  end

  def self.sample(capture: method(:capture), compilers: limits.fetch("foreign_compilers"))
    values = capture.call(SYSCTL, *REQUIRED, *OPTIONAL).lines.filter_map do |line|
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
    limit = ->(name) { thermal[/#{name}\s*=\s*(\d+)/, 1]&.to_i }
    # Executable names sorted by CPU; arguments are never read or recorded.
    processes = capture.call(PS, "-A", "-r", "-o", "pcpu=", "-o", "pid=", "-o", "ppid=", "-o", "comm=").lines.filter_map do |line|
      cpu, pid, parent, command = line.strip.split(/\s+/, 4)
      [cpu, pid, parent, File.basename(command)] if command
    end
    parents = processes.to_h { |_, pid, parent, _| [pid, parent] }
    names = processes.to_h { |_, pid, _, name| [pid, name] }
    ancestors = [parents[Process.pid.to_s]]
    ancestors << parents[ancestors.last] while ancestors.last && ancestors.length < 64
    enclosing = ancestors.compact.find { |pid| ENCLOSING_BUILDS.include?(names[pid]) || compilers.include?(names[pid]) }
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
      "top" => processes.first(3).map { |cpu, pid, _, name| "#{cpu} #{pid} #{name}" },
      "compilers" => processes.filter_map { |_, pid, _, name| "#{name} #{pid}" if compilers.include?(name) },
      "enclosing_build" => ("#{names[enclosing]} #{enclosing}" if enclosing) }
  end

  # Every reason a new heavy job must not start now; empty when admitted.
  def self.reasons(limits, sample)
    return [] if sample["enclosing_build"]

    found = []
    cpus = sample.fetch("cpus")
    ceiling = limits.fetch("max_load_percent_of_cpus") * cpus / 100.0
    current = sample.fetch("load").first
    if current > ceiling
      found << format("1-minute load average %.2f exceeds %.2f (%d%% of %d CPUs)",
                      current, ceiling, limits.fetch("max_load_percent_of_cpus"), cpus)
    end
    pressure = sample.fetch("pressure")
    found << "memory pressure is #{PRESSURE.fetch(pressure)}" unless pressure == 1
    swap = sample.fetch("swap_used_mib")
    if swap > limits.fetch("max_swap_used_mib")
      found << format("swap in use %.0f MiB exceeds %d MiB", swap, limits.fetch("max_swap_used_mib"))
    end
    compressor = 100.0 * sample.fetch("compressor_mib") / sample.fetch("memory_mib")
    if compressor > limits.fetch("max_compressor_percent_of_memory")
      found << format("memory compressor occupies %.0f%% of memory, above %d%%",
                      compressor, limits.fetch("max_compressor_percent_of_memory"))
    end
    { "cpu_speed_limit" => "CPU_Speed_Limit", "cpu_scheduler_limit" => "CPU_Scheduler_Limit" }.each do |key, name|
      value = sample[key]
      found << "#{name} is #{value} (thermal throttling)" if value && value < 100
    end
    available = sample["cpu_available"]
    found << "only #{available} of #{cpus} CPUs available (thermal throttling)" if available && available < cpus
    # The lease owner has started nothing yet, so these belong to work this
    # lease does not coordinate: a package-manager source build, an IDE, another tool.
    running = Array(sample["compilers"])
    found << "a compiler is already running (#{running.first(4).join(', ')})" unless running.empty?
    found
  end

  def self.refusal(limits, sample)
    found = reasons(limits, sample)
    return nil if found.empty?

    "Heavy job refused, the host is already loaded: #{found.join('; ')}. " \
      "Inspect with `ruby scripts/native_job.rb status`; wait or stop the other load."
  end

  # Unreadable telemetry blocks the job, like every other native guard here.
  def self.check(sampler: method(:sample), policy: method(:limits))
    refusal(policy.call, sampler.call)
  rescue StandardError => error
    "Host load inspection failed (#{error.class}: #{error.message}); heavy job blocked."
  end
end
