# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "timeout"

# Readings and invalid-input errors for a supervised Simulator session. Resource
# readings are information only: they become notes in the report and never
# refuse, delay or stop a session (Pietro removed the host guards on 2026-11-22).
module SimulatorResources
  # Reference sizes for the notes; the readings behind the old admission limits.
  NOTE_FREE_DISK_GIB = 15
  NOTE_FREE_PERCENT = 40
  NOTE_SWAP_MIB = 1024
  NOTE_CPU_IDLE_PERCENT = 70

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
    cpu_sampler = File.expand_path("simulator_cpu_idle.rb", __dir__)
    idle = Float(capture.call(RbConfig.ruby, cpu_sampler, seconds: 8).strip, exception: false)
    raise Refusal, "Missing CPU idle telemetry" unless idle
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

  # Sentences for readings outside the reference sizes; empty for a calm host.
  def self.notes(sample)
    found = []
    found << "Memory pressure is #{{ 2 => 'warning', 4 => 'critical' }.fetch(sample['pressure'])}" unless sample["pressure"] == 1
    found << "Reported free memory #{sample['free_percent'].round}% is below #{NOTE_FREE_PERCENT}%" if sample["free_percent"] < NOTE_FREE_PERCENT
    found << "Swap #{sample['swap_mib'].round} MiB exceeds #{NOTE_SWAP_MIB} MiB" if sample["swap_mib"] > NOTE_SWAP_MIB
    found << "CPU idle #{sample['cpu_idle'].round}% is below #{NOTE_CPU_IDLE_PERCENT}%" if sample["cpu_idle"] < NOTE_CPU_IDLE_PERCENT
    found << "Free disk below #{NOTE_FREE_DISK_GIB} GiB" if sample["free_bytes"] < NOTE_FREE_DISK_GIB * 1024**3
    found
  end
end
