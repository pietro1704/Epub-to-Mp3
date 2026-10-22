# frozen_string_literal: true

module NativeSimulatorSession
  class Monitor
    attr_reader :denial

    LIMITS = { "minimum_free_percent" => 20, "minimum_disk_bytes" => 8 * 1024**3,
               "maximum_swap_growth_bytes" => 256 * 1024**2,
               "maximum_sample_seconds" => 5.0, "query_timeout_seconds" => 2.0 }.freeze
    def initialize(reader, log, duration)
      @reader, @log, @duration = reader, log, duration
      @buffer = +""
      @policy = false
      @sample = nil
      @baseline = nil
      @denial = nil
    end

    def pump
      16.times do
        bytes = @reader.read_nonblock(4096, exception: false)
        break if bytes == :wait_readable
        if bytes.nil?
          deny(Stop.new("Resource monitor ended unexpectedly"))
          break
        end
        @log.write(bytes)
        @log.flush
        @buffer << bytes
        raise Stop, "Resource monitor record exceeds limit" if @buffer.bytesize > 65_536
        while (line = @buffer.slice!(/\A[^\n]*\n/))
          record = JSON.parse(line)
          raise Stop, "Resource monitor record must be an object" unless record.is_a?(Hash)
          consume(record)
        end
      end
    rescue Stop => error
      deny(error)
    rescue JSON::ParserError, IOError, SystemCallError => error
      deny(Stop.new("Invalid resource monitor stream: #{error.class}"))
    end

    def deny(error)
      return if @denial&.fatal
      @denial = error if error.fatal || @denial.nil? || (@denial.is_a?(ResourceDenied) && !error.is_a?(ResourceDenied))
    end

    def consume(record)
      case record["event"]
      when "policy"
        unless !@policy && record["limits"] == LIMITS && record["load1_limit"] == "min(6.0, 0.75 * logical_cpus)" &&
               record["duration_seconds"] == @duration && record["interval_seconds"].is_a?(Numeric) && record["interval_seconds"].between?(0.1, 5)
          raise Stop, "Resource monitor policy mismatch"
        end
        @policy = true
      when "sample"
        raise Stop, "Resource sample preceded policy" unless @policy
        sample = record["sample"]
        raise Stop, "Invalid resource sample" unless sample.is_a?(Hash)
        %w[collected_monotonic started_monotonic collection_seconds memory_bytes logical_cpus memory_free_percent disk_free_bytes swap_used_bytes].each do |key|
          value = sample[key]
          raise Stop, "Invalid resource sample field: #{key}" unless value.is_a?(Numeric) && value.finite? && value >= 0
        end
        load = sample["load_averages"]
        panics = sample["panic_identities"]
        elapsed = sample["collected_monotonic"] - sample["started_monotonic"]
        # Allow only floating-point round-trip noise in the producer's subtraction.
        consistent_duration = (sample["collection_seconds"] - elapsed).abs <= 1e-6
        unless load.is_a?(Array) && load.length == 3 && load.all? { |value| value.is_a?(Numeric) && value.finite? && value >= 0 } &&
               panics.is_a?(Array) && panics.length <= 4096 && panics.all? { |value| value.is_a?(String) && value.bytesize <= 4096 } &&
               sample["logical_cpus"].positive? && sample["memory_bytes"].positive? && sample["memory_free_percent"] <= 100 &&
               elapsed.between?(0, 5) && consistent_duration && sample["collection_seconds"] <= 5 &&
               (!@sample || sample["collected_monotonic"] > @sample["collected_monotonic"])
          raise Stop, "Invalid or replayed resource sample"
        end
        @baseline ||= sample
        if (panics - @baseline["panic_identities"]).any?
          deny(Stop.new("New panic report detected", fatal: true))
        elsif record["decision"] != "allow" || record["reasons"] != [] ||
              sample["memory_free_percent"] < 20 || sample["disk_free_bytes"] < LIMITS["minimum_disk_bytes"] ||
              sample["swap_used_bytes"] - @baseline["swap_used_bytes"] > LIMITS["maximum_swap_growth_bytes"] ||
              load.first > [6.0, 0.75 * sample["logical_cpus"]].min
          deny(ResourceDenied.new("Resource monitor denied session"))
        end
        @sample = sample
      when "collection_error", "final"
        reasons = record["reasons"]
        fatal = record["fatal_stop"] == true || (reasons.is_a?(Array) && reasons.any? { |reason| reason.is_a?(String) && reason.start_with?("new or changed panic report detected") })
        deny(Stop.new(fatal ? "New panic report detected" : "Resource monitor stopped or failed", fatal: fatal))
      else
        raise Stop, "Unknown resource monitor record"
      end
    end

    def check!(cleanup: false)
      pump
      raise @denial if @denial && (!cleanup || !@denial.is_a?(ResourceDenied))
      return false unless @sample
      age = NativeSimulatorSession.now - @sample["collected_monotonic"]
      raise Stop, "Resource monitor sample is stale" unless age.between?(0, 5)
      true
    end
  end
end
