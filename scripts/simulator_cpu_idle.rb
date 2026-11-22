# frozen_string_literal: true

require "fiddle"

module SimulatorCPUIdle
  # Darwin host_cpu_load_info exposes four unsigned 32-bit Mach CPU counters.
  HOST_CPU_LOAD_INFO = 3
  IDLE_STATE = 2
  TICK_COUNT = 4
  COUNTER_MASK = (1 << 32) - 1

  def self.percentage(before, after)
    valid = [before, after].all? do |sample|
      sample.size == TICK_COUNT && sample.all? { |tick| tick.is_a?(Integer) && tick.between?(0, COUNTER_MASK) }
    end
    raise ArgumentError, "Invalid Mach CPU tick sample" unless valid

    ticks = after.zip(before).map { |current, previous| (current - previous) & COUNTER_MASK }
    total = ticks.sum
    raise ArgumentError, "Mach CPU ticks did not advance" if total.zero?

    100.0 * ticks.fetch(IDLE_STATE) / total
  end

  def self.read_ticks
    library = Fiddle::Handle::DEFAULT
    integer = Fiddle::TYPE_INT
    port_type = -integer
    pointer = Fiddle::TYPE_VOIDP
    host_self = Fiddle::Function.new(library["mach_host_self"], [], port_type)
    statistics = Fiddle::Function.new(library["host_statistics"], [port_type, integer, pointer, pointer], integer)
    deallocate = Fiddle::Function.new(library["mach_port_deallocate"], [port_type, port_type], integer)
    task_port = Fiddle::Pointer.new(library["mach_task_self_"])[0, 4].unpack1("L")
    counters = Fiddle::Pointer.malloc(TICK_COUNT * 4, Fiddle::RUBY_FREE)
    count = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
    count[0, 4] = [TICK_COUNT].pack("L")

    host_port = host_self.call
    raise "Could not obtain the Mach host port" if host_port.zero?

    begin
      status = statistics.call(host_port, HOST_CPU_LOAD_INFO, counters, count)
      unless status.zero? && count[0, 4].unpack1("L") == TICK_COUNT
        raise "Invalid Mach CPU statistics (kernel status #{status})"
      end

      counters[0, TICK_COUNT * 4].unpack("L4")
    ensure
      deallocate.call(task_port, host_port)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  before = SimulatorCPUIdle.read_ticks
  sleep 1
  puts SimulatorCPUIdle.percentage(before, SimulatorCPUIdle.read_ticks)
end
