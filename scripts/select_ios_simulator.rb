#!/usr/bin/env ruby
# frozen_string_literal: true

# Pick the best iOS Simulator destination for `xcodebuild`.
#
# Usage
# -----
# - `select_ios_simulator.rb`           reads `xcrun simctl list -j devices available`
# - `select_ios_simulator.rb --stdin`   reads the same JSON from stdin (tests)
#
# Prints a destination string in the form `platform=iOS Simulator,id=<udid>`
# on stdout and exits 0 on success, or exits 1 with an actionable message on
# stderr when nothing usable is installed. Exit 2 reports a failed simctl
# query, malformed JSON, an invalid IOS_MAX_SIMULATOR_MAJOR or a usage error.
#
# Preference order:
#
# 1. iPhone SE (any generation) on the oldest allowed installed iOS runtime.
# 2. Any iPhone on the oldest allowed installed iOS runtime.
# 3. Any iOS device (iPad, etc.) on the oldest allowed installed iOS runtime.
#
# By default, local selection keeps runtimes at or below iOS 17, matching the
# documented CoreSimulator panic history on this Intel Mac. Set
# IOS_ALLOW_RECENT_SIMULATOR=1 or IOS_MAX_SIMULATOR_MAJOR=<major> to opt in.
#
# `isAvailable=false` devices are ignored; that matches Xcode's own filter and
# avoids picking a simulator whose runtime profile is missing. The selector
# never boots a simulator.

require 'json'
require 'open3'

module SelectIosSimulator
  PROG = 'select_ios_simulator.rb'
  RUNTIME_PREFIX = 'com.apple.CoreSimulator.SimRuntime.iOS-'
  RUNTIME_VERSION = /iOS-(\d+)-(\d+)/
  DEFAULT_MAX_RUNTIME_MAJOR = 17
  QUERY = %w[xcrun simctl list -j devices available].freeze
  DESCRIPTION = 'Pick the best iOS Simulator destination for `xcodebuild`.'
  USAGE = "usage: #{PROG} [-h] [--stdin]"
  HELP = <<~TEXT
    #{USAGE}

    #{DESCRIPTION}

    options:
      -h, --help  show this help message and exit
      --stdin     Read simctl JSON from stdin (used by tests).
  TEXT

  module_function

  # Mirrors Python truthiness for JSON values.
  def truthy?(value)
    !(value.nil? || value == false || value == 0 || ((value.is_a?(String) || value.is_a?(Array) ||
      value.is_a?(Hash)) && value.empty?))
  end

  # Newest iOS runtime major allowed for local simulator builds, or nil when unbounded.
  def max_runtime_major(env: ENV, stderr: $stderr)
    return nil if env['IOS_ALLOW_RECENT_SIMULATOR'] == '1'

    raw = env['IOS_MAX_SIMULATOR_MAJOR']
    return DEFAULT_MAX_RUNTIME_MAJOR if raw.nil? || raw.empty?

    begin
      Integer(raw.strip, 10)
    rescue ArgumentError
      stderr.print('select_ios_simulator: IOS_MAX_SIMULATOR_MAJOR must be an integer', "\n")
      exit 2
    end
  end

  # [major, minor] for an iOS runtime identifier; unknown versions sort first.
  def runtime_sort_key(runtime)
    match = RUNTIME_VERSION.match(runtime)
    match ? [match[1].to_i, match[2].to_i] : [0, 0]
  end

  # Allowed iOS runtime keys, oldest first (stable for equal versions, like Python's sort).
  def ios_runtimes(devices, env: ENV, stderr: $stderr)
    max_major = max_runtime_major(env: env, stderr: stderr)
    runtimes = devices.keys.select do |runtime|
      runtime.start_with?(RUNTIME_PREFIX) && (max_major.nil? || runtime_sort_key(runtime)[0] <= max_major)
    end
    runtimes.each_with_index.sort_by { |runtime, index| [runtime_sort_key(runtime), index] }.map(&:first)
  end

  def available?(device)
    truthy?(device.fetch('isAvailable', false))
  end

  def device_name(device)
    name = device.fetch('name', '')
    name.is_a?(String) ? name.downcase : ''
  end

  def iphone_se?(device)
    device_name(device).start_with?('iphone se')
  end

  def iphone?(device)
    device_name(device).start_with?('iphone')
  end

  # Best simulator hash, or nil when nothing usable is installed.
  def select(payload, env: ENV, stderr: $stderr)
    devices = payload.fetch('devices', {})
    devices = {} unless truthy?(devices)
    runtimes = ios_runtimes(devices, env: env, stderr: stderr)
    candidates = runtimes.flat_map { |runtime| devices.fetch(runtime, []) }
    candidates.find { |device| available?(device) && iphone_se?(device) } ||
      candidates.find { |device| available?(device) && iphone?(device) } ||
      candidates.find { |device| available?(device) }
  end

  def capture(command)
    stdout, stderr, status = Open3.capture3(*command)
    [stdout, stderr, status.exitstatus || 1]
  rescue SystemCallError => error
    ['', error.message, 1]
  end

  def read_payload(use_stdin, stdin: $stdin, stderr: $stderr, runner: method(:capture))
    if use_stdin
      raw = stdin.read
    else
      stdout, error_output, status = runner.call(QUERY.dup)
      unless status.zero?
        stderr.print("select_ios_simulator: `xcrun simctl list` failed:\n#{error_output}", "\n")
        exit 2
      end
      raw = stdout
    end
    begin
      JSON.parse(raw, allow_nan: true)
    rescue JSON::ParserError => error
      stderr.print("select_ios_simulator: malformed simctl JSON: #{error.message}", "\n")
      exit 2
    end
  end

  # Python-style repr used for the "no UDID" diagnostic so its text matches the original tool.
  def python_repr(value)
    case value
    when Hash then "{#{value.map { |key, item| "#{python_repr(key)}: #{python_repr(item)}" }.join(', ')}}"
    when Array then "[#{value.map { |item| python_repr(item) }.join(', ')}]"
    when String then python_string_repr(value)
    when true then 'True'
    when false then 'False'
    when nil then 'None'
    when Float then python_float_repr(value)
    else value.to_s
    end
  end

  def python_float_repr(value)
    return 'nan' if value.nan?
    return value.positive? ? 'inf' : '-inf' if value.infinite?

    value.to_s.sub(/\.0e/, 'e')
  end

  def python_string_repr(text)
    quote = text.include?("'") && !text.include?('"') ? '"' : "'"
    body = text.each_char.map do |char|
      case char
      when '\\' then '\\\\'
      when quote then "\\#{quote}"
      when "\n" then '\\n'
      when "\r" then '\\r'
      when "\t" then '\\t'
      else char.ord < 0x20 || char.ord == 0x7f ? format('\\x%02x', char.ord) : char
      end
    end
    "#{quote}#{body.join}#{quote}"
  end

  def long_option(argument, names)
    flag = argument.split('=', 2).first
    return flag if names.include?(flag)
    return nil unless flag.start_with?('--') && flag.length > 2

    matches = names.select { |name| name.start_with?(flag) }
    matches.length == 1 ? matches.first : nil
  end

  def usage_error(stderr, message)
    stderr.print(USAGE, "\n")
    stderr.print("#{PROG}: error: #{message}", "\n")
    2
  end

  # Returns [use_stdin, exit_status_or_nil], mirroring argparse behavior and exit 2.
  def parse_arguments(argv, stdout:, stderr:)
    use_stdin = false
    extras = []
    arguments = argv.dup
    until arguments.empty?
      argument = arguments.shift
      if argument == '--'
        extras.concat(arguments)
        break
      end
      option = argument == '-h' ? '--help' : long_option(argument, %w[--help --stdin])
      if option && argument.include?('=') && argument.start_with?('--')
        explicit = argument.split('=', 2).last
        return [false, usage_error(stderr, "argument #{option == '--help' ? '-h/--help' : option}: " \
                                           "ignored explicit argument '#{explicit}'")]
      end
      case option
      when '--help'
        stdout.print HELP
        return [false, 0]
      when '--stdin' then use_stdin = true
      else extras << argument
      end
    end
    return [false, usage_error(stderr, "unrecognized arguments: #{extras.join(' ')}")] unless extras.empty?

    [use_stdin, nil]
  end

  def main(argv = ARGV, env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr, runner: method(:capture))
    use_stdin, status = parse_arguments(argv, stdout: stdout, stderr: stderr)
    return status if status

    payload = read_payload(use_stdin, stdin: stdin, stderr: stderr, runner: runner)
    pick = select(payload, env: env, stderr: stderr)
    if pick.nil?
      stderr.puts 'select_ios_simulator: no available allowed iOS simulator. ' \
                  'Install an iOS runtime at or below the configured maximum.'
      return 1
    end

    udid = pick['udid']
    unless truthy?(udid)
      stderr.print("select_ios_simulator: chosen device has no UDID: #{python_repr(pick)}", "\n")
      return 1
    end

    stdout.print("platform=iOS Simulator,id=#{udid}", "\n")
    0
  end
end

exit SelectIosSimulator.main if $PROGRAM_NAME == __FILE__
