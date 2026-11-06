# frozen_string_literal: true

require "json"
require "open3"
require "timeout"

module SimulatorResources
  class Refusal < StandardError; end

  # Every inspection has a deadline; a broken telemetry command cannot hang cleanup.
  def self.capture(*argv, seconds: 4, environment: {})
    output = error = nil
    status = nil
    complete = false
    Open3.popen3(environment, *argv, pgroup: true) do |input, stdout, stderr, waiter|
      input.close
      readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
      begin
        Timeout.timeout(seconds) do
          status = waiter.value
          output, error = readers.map(&:value)
          complete = true
        end
      ensure
        unless complete
          Process.kill("KILL", -waiter.pid) rescue Errno::ESRCH
          waiter.join
        end
        readers.each { |thread| thread.kill.join unless complete }
      end
    end
    raise Refusal, "#{argv.first}: #{error.to_s.strip}" unless status.success?
    output
  rescue Timeout::Error
    raise Refusal, "Telemetry deadline exceeded: #{argv.first}"
  end

  def self.number(text, expression, label)
    match = text.match(expression)
    raise Refusal, "Missing #{label} telemetry" unless match
    Float(match[1])
  end

  def self.snapshot(root:, capture: method(:capture))
    Timeout.timeout(12) { collect(root: root, capture: capture) }
  rescue Timeout::Error
    raise Refusal, "Resource snapshot deadline exceeded"
  end

  def self.collect(root:, capture:)
    pressure = capture.call("/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level").strip
    raise Refusal, "Invalid memory pressure" unless %w[1 2 4].include?(pressure)
    free = number(capture.call("/usr/bin/memory_pressure", "-Q"), /System-wide memory free percentage:\s*(\d+)%/, "memory")
    swap = number(capture.call("/usr/sbin/sysctl", "-n", "vm.swapusage"), /used\s*=\s*([\d.]+)M/, "swap")
    vm = capture.call("/usr/bin/vm_stat")
    swapouts = number(vm, /Swapouts:\s*(\d+)/, "swapouts")
    page_size = number(vm, /page size of (\d+) bytes/, "page size")
    compressed = number(vm, /Pages occupied by compressor:\s*(\d+)/, "compression") * page_size
    cpu = capture.call("/usr/bin/top", "-l", "2", "-s", "1", "-n", "0", seconds: 8)
    idle = number(cpu.lines.grep(/CPU usage:/).last.to_s, /([\d.]+)% idle/, "CPU idle")
    disk = capture.call("/bin/df", "-Pk", root).lines.last.to_s.split
    raise Refusal, "Invalid free disk telemetry" unless disk[3]&.match?(/\A\d+\z/)
    result = { "pressure" => Integer(pressure), "free_percent" => free,
               "swap_mib" => swap, "swapouts" => swapouts, "compressed_bytes" => compressed,
               "cpu_idle" => idle, "free_bytes" => Integer(disk[3]) * 1024 }
    validate(result)
    result
  end

  def self.validate(sample)
    %w[pressure free_percent swap_mib swapouts compressed_bytes cpu_idle free_bytes].each do |key|
      value = sample.fetch(key)
      raise Refusal, "Invalid #{key}" unless value.is_a?(Numeric) && value.finite? && value >= 0
    end
    raise Refusal, "Invalid pressure level" unless [1, 2, 4].include?(sample["pressure"])
    %w[free_percent cpu_idle].each do |key|
      raise Refusal, "Invalid #{key}" unless sample[key] <= 100
    end
  rescue KeyError => error
    raise Refusal, error.message
  end

  def self.admission(sample, initial, stable_existing_swap: false, previous: initial)
    validate(sample)
    validate(initial)
    return "Memory pressure is not normal" unless sample["pressure"] == 1
    minimum_free = stable_existing_swap ? 50 : 40
    return "Reported free memory below #{minimum_free}%" if sample["free_percent"] < minimum_free
    return "Swap exceeds 1 GiB" if !stable_existing_swap && sample["swap_mib"] > 1024
    if stable_existing_swap
      validate(previous)
      if sample["swap_mib"] > initial["swap_mib"] || sample["swap_mib"] > previous["swap_mib"]
        return "Swap allocation grew during baseline"
      end
    end
    return "Swapouts increased during baseline" if sample["swapouts"] != initial["swapouts"]
    return "CPU idle below 70%" if sample["cpu_idle"] < 70
    return "Free disk below 20 GiB" if sample["free_bytes"] < 20 * 1024**3
    nil
  end

  class Monitor
    def initialize(initial, observation_only: false)
      SimulatorResources.validate(initial)
      @initial = initial
      @since = {}
      @observation_only = observation_only
    end

    def check(sample, now)
      SimulatorResources.validate(sample)
      return "Critical memory pressure" if sample["pressure"] == 4
      return "Free disk below 20 GiB" if sample["free_bytes"] < 20 * 1024**3
      conditions = {
        "Memory pressure warning" => [sample["pressure"] != 1, 10],
        "Reported free memory below 25%" => [sample["free_percent"] < 25, 10],
        "Swap grew by 256 MiB" => [sample["swap_mib"] - @initial["swap_mib"] >= 256, 10],
        "CPU idle below 10%" => [sample["cpu_idle"] < 10, 30]
      }
      conditions.select! { |reason, _| reason == "Memory pressure warning" } if @observation_only
      conditions.each do |reason, (active, duration)|
        @since.delete(reason) unless active
        next unless active
        @since[reason] ||= now
        return reason if now - @since[reason] >= duration
      end
      nil
    end
  end
end
