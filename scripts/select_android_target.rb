#!/usr/bin/env ruby
# frozen_string_literal: true

# Select an Android device, preferring hardware and then the lightest AVD.
#
# `--devices-json` reads `flutter devices --machine` JSON from stdin and prints a
# physical Android device ID, else a running emulator ID (exit 1 when none).
# `--lightest-avd` prints the AVD name with the lowest resource footprint under
# ANDROID_AVD_HOME (default ~/.android/avd), exit 1 when none. Usage errors exit 2.

require 'json'

module SelectAndroidTarget
  PROG = 'select_android_target.rb'
  USAGE = "usage: #{PROG} [-h] (--devices-json | --lightest-avd)"
  HELP = <<~TEXT
    #{USAGE}

    options:
      -h, --help      show this help message and exit
      --devices-json
      --lightest-avd
  TEXT
  SIZE = /\A\s*(\d+(?:\.\d+)?)\s*([KMG]?)(?:B)?\s*\z/i
  MULTIPLIERS = { 'K' => 1.0 / 1024, 'M' => 1, 'G' => 1024 }.freeze
  # Python's str.splitlines boundaries.
  LINE_BREAKS = /\r\n|[\n\r\v\f\x1c\x1d\x1e\u0085  ]/

  module_function

  # Mirrors Python truthiness for JSON values.
  def truthy?(value)
    !(value.nil? || value == false || value == 0 || ((value.is_a?(String) || value.is_a?(Array) ||
      value.is_a?(Hash)) && value.empty?))
  end

  # Python's str() for JSON scalars.
  def python_str(value)
    case value
    when nil then 'None'
    when true then 'True'
    when false then 'False'
    else value.to_s
    end
  end

  # A physical Android ID first, then a running Android emulator, else nil.
  def select_running_android_device(devices)
    android_devices = devices.select do |device|
      platform = device.fetch('targetPlatform', '')
      platform.is_a?(String) && platform.downcase.start_with?('android') && truthy?(device['id'])
    end
    physical = android_devices.reject { |device| truthy?(device.fetch('emulator', false)) }
    selected = physical.empty? ? android_devices : physical
    selected.empty? ? nil : python_str(selected.first['id'])
  end

  def size_mebibytes(value, default)
    return default if value.nil? || value.empty?

    match = SIZE.match(value)
    return default unless match

    (Float(match[1]) * MULTIPLIERS.fetch(match[2].upcase, 1)).to_i
  end

  def read_avd_config(path)
    File.read(path, encoding: 'UTF-8').split(LINE_BREAKS).each_with_object({}) do |line, config|
      next unless line.include?('=') && !line.lstrip.start_with?('#')

      key, value = line.split('=', 2)
      config[key] = value
    end
  end

  # Python's PurePath.stem: drop the last suffix unless the name is only a dotted prefix.
  def stem(name)
    index = name.rindex('.')
    index && index.positive? && index < name.length - 1 ? name[0...index] : name
  end

  # The available AVD with the lowest resource footprint, or nil.
  def find_lightest_avd(avd_root)
    root = avd_root.to_s
    # The root is literal (like pathlib); only `*.avd` is a pattern, and pathlib's `*` also matches dot names.
    paths = Dir.glob('*.avd/config.ini', File::FNM_DOTMATCH, base: root).map { |relative| File.join(root, relative) }
    candidates = paths.map do |config_path|
      config = read_avd_config(config_path)
      name = stem(File.basename(File.dirname(config_path)))
      ram_mib = size_mebibytes(config['hw.ramSize'], 4096)
      width = size_mebibytes(config['hw.lcd.width'], 1440)
      height = size_mebibytes(config['hw.lcd.height'], 2960)
      cores = size_mebibytes(config['hw.cpu.ncore'], 4)
      disk_mib = size_mebibytes(config['disk.dataPartition.size'], 8192)
      [[ram_mib, width * height, cores, disk_mib, name.downcase], name]
    end
    candidates.min&.last
  end

  def default_avd_root(env)
    root = env.fetch('ANDROID_AVD_HOME') { File.join(Dir.home, '.android', 'avd') }
    root.empty? ? '.' : root
  end

  def long_option(flag, names)
    return flag if names.include?(flag)
    return nil unless flag.start_with?('--') && flag.length > 2

    matches = names.select { |name| name.start_with?(flag) }
    matches.length == 1 ? matches.first : nil
  end

  class UsageError < StandardError; end

  # Returns [mode, exit_status_or_nil], mirroring argparse's required exclusive group and exit 2.
  def parse_arguments(argv, stdout:, stderr:)
    mode = nil
    extras = []
    arguments = argv.dup
    until arguments.empty?
      argument = arguments.shift
      if argument == '--'
        extras.concat(arguments)
        break
      end
      flag, equals, explicit = argument.partition('=')
      option = argument == '-h' ? '--help' : long_option(argument.start_with?('--') ? flag : argument,
                                                          %w[--help --devices-json --lightest-avd])
      if option && !equals.empty?
        raise UsageError, "argument #{option == '--help' ? '-h/--help' : option}: ignored explicit argument '#{explicit}'"
      end

      case option
      when '--help'
        stdout.print HELP
        return [nil, 0]
      when '--devices-json', '--lightest-avd'
        raise UsageError, "argument #{option}: not allowed with argument #{mode}" if mode && mode != option

        mode = option
      else extras << argument
      end
    end
    raise UsageError, 'one of the arguments --devices-json --lightest-avd is required' unless mode
    raise UsageError, "unrecognized arguments: #{extras.join(' ')}" unless extras.empty?

    [mode, nil]
  rescue UsageError => error
    stderr.print(USAGE, "\n")
    stderr.print("#{PROG}: error: #{error.message}", "\n")
    [nil, 2]
  end

  def main(argv = ARGV, env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr)
    mode, status = parse_arguments(argv, stdout: stdout, stderr: stderr)
    return status if status

    selected =
      if mode == '--devices-json'
        begin
          devices = JSON.parse(stdin.read, allow_nan: true)
          # Python crashed (exit 1) on a non-list payload; report it instead with the same status.
          raise JSON::ParserError, 'expected a JSON array of devices' unless devices.is_a?(Array)

          select_running_android_device(devices)
        rescue JSON::ParserError => error
          stderr.print("#{PROG}: malformed devices JSON: #{error.message}", "\n")
          return 1
        end
      else
        find_lightest_avd(default_avd_root(env))
      end
    return 1 if selected.nil? || selected.empty?

    stdout.print(selected, "\n")
    0
  end
end

exit SelectAndroidTarget.main if $PROGRAM_NAME == __FILE__
