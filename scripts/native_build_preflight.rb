# frozen_string_literal: true

require "json"
require "open3"

# A read-only snapshot, used in addition to the shared heavy-job lease.
module NativeBuildPreflight
  def self.check(host: RUBY_PLATFORM, runner: ->(*args) { Open3.capture3(*args) })
    return nil unless host.match?(/(?:x86_64|i386).*darwin/)

    output, _, status = runner.call("xcrun", "simctl", "list", "devices", "--json")
    return "Cannot inspect Simulator state; native compilation blocked." unless status.success?

    payload = JSON.parse(output)
    devices = payload.is_a?(Hash) ? payload["devices"] : nil
    valid_rows = ->(rows) do
      rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row["state"].is_a?(String) }
    end
    unless devices.is_a?(Hash) && devices.values.all?(&valid_rows)
      return "Invalid Simulator state; native compilation blocked."
    end
    if devices.values.flatten.any? { |device| device["state"] != "Shutdown" }
      return "Shut down all Simulators and wait for shutdown before native compilation."
    end

    _, _, status = runner.call("pgrep", "-f", "SimMetalHost")
    return "Wait for SimMetalHost to exit before native compilation." if status.success?
    return "Cannot inspect SimMetalHost; native compilation blocked." unless status.exitstatus == 1

    nil
  rescue JSON::ParserError, KeyError, SystemCallError => error
    "Native build preflight failed (#{error.class}); compilation blocked."
  end
end

if $PROGRAM_NAME == __FILE__
  error = NativeBuildPreflight.check
  warn error if error
  exit(error ? 75 : 0)
end
