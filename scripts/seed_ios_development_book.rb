#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage the local development EPUB in a newly installed iOS app container.
#
# Exit status: 0 staged, 1 xcrun failure, 2 usage error, 3 source EPUB unavailable
# (callers treat 3 as "skip seeding" and continue launching the app).

require 'fileutils'
require 'open3'

module SeedIosDevelopmentBook
  PROG = 'seed_ios_development_book.rb'
  BUNDLE_ID = 'com.pietrocode.epubtomp3'
  STAGED_FILENAME = 'EpubToMp3DevelopmentSeed.epub'
  MISSING_SOURCE_EXIT = 3
  DEFAULT_BOOK = 'The Lord of the Rings (J.R.R. Tolkien) (z-library.sk, 1lib.sk, z-lib.sk).epub'
  TARGETS = %w[simulator device].freeze
  DESCRIPTION = 'Stage the local development EPUB in a newly installed iOS app container.'
  USAGE = "usage: #{PROG} [-h] --target {simulator,device}\n" \
          "#{' ' * "usage: #{PROG} ".length}--identifier IDENTIFIER"
  HELP = <<~TEXT
    #{USAGE}

    #{DESCRIPTION}

    options:
      -h, --help            show this help message and exit
      --target {simulator,device}
      --identifier IDENTIFIER
  TEXT

  # Raised for a non-zero xcrun exit, mirroring subprocess.CalledProcessError.
  class CommandError < StandardError
    attr_reader :command, :status, :stderr_text

    def initialize(command, status, stderr_text)
      @command = command
      @status = status
      @stderr_text = stderr_text
      super("Command '[#{command.map { |part| "'#{part}'" }.join(', ')}]' returned non-zero exit status #{status}.")
    end
  end

  module_function

  # Python's Path.expanduser: only a leading `~` or `~user` component is expanded.
  def expand_user(path)
    return path unless path.start_with?('~')

    head, separator, rest = path.partition('/')
    File.expand_path(head) + separator + rest
  rescue ArgumentError
    path
  end

  def development_book_source(env: ENV, home: nil)
    configured = env.fetch('IOS_DEVELOPMENT_SEED_SOURCE', '').strip
    legacy_configured = env.fetch('IOS_DEVELOPMENT_SEED_BOOK', '').strip
    configured = legacy_configured if configured.empty? && !['', '0', '1'].include?(legacy_configured)
    candidates =
      if configured.empty?
        home ||= Dir.home
        [File.join(home, 'Downloads', 'Ebooks', DEFAULT_BOOK), File.join(home, 'Downloads', 'ebook', DEFAULT_BOOK)]
      else
        [expand_user(configured)]
      end
    candidates.find { |path| File.file?(path) }
  end

  def run(command)
    stdout, stderr, status = Open3.capture3(*command)
    raise CommandError.new(command, status.exitstatus || status.termsig, stderr) unless status.success?

    stdout
  end

  def stage_for_simulator(source, identifier, runner: method(:run))
    container = runner.call(['xcrun', 'simctl', 'get_app_container', identifier, BUNDLE_ID, 'data']).strip
    container = '.' if container.empty?
    target = File.join(container, 'Documents', STAGED_FILENAME)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(source, target, preserve: true) if !File.file?(target) || File.size(source) != File.size(target)
    target
  end

  def stage_for_device(source, identifier, runner: method(:run))
    destination = "Documents/#{STAGED_FILENAME}"
    runner.call(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', identifier, '--source', source,
                 '--destination', destination, '--domain-type', 'appDataContainer',
                 '--domain-identifier', BUNDLE_ID])
    destination
  end

  def long_option(flag, names)
    return flag if names.include?(flag)
    return nil unless flag.start_with?('--') && flag.length > 2

    matches = names.select { |name| name.start_with?(flag) }
    matches.length == 1 ? matches.first : nil
  end

  # argparse treats `-x` (but not `-`, `-5` or `-1.5`) as an option, so it cannot be a value.
  def option_like?(argument)
    argument.start_with?('-') && argument != '-' && !argument.match?(/\A-\d+\z|\A-\d*\.\d+\z/)
  end

  class UsageError < StandardError; end

  # Returns [options_hash, exit_status_or_nil], mirroring argparse messages and exit 2.
  def parse_arguments(argv, stdout:, stderr:)
    options = {}
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
                                                          %w[--help --target --identifier])
      case option
      when '--help'
        raise UsageError, "argument -h/--help: ignored explicit argument '#{explicit}'" unless equals.empty?

        stdout.print HELP
        return [options, 0]
      when '--target', '--identifier'
        value =
          if !equals.empty? then explicit
          elsif arguments.empty? || option_like?(arguments.first)
            raise UsageError, "argument #{option}: expected one argument"
          else arguments.shift
          end
        if option == '--target' && !TARGETS.include?(value)
          raise UsageError, "argument --target: invalid choice: '#{value}' (choose from 'simulator', 'device')"
        end

        options[option.delete_prefix('--').to_sym] = value
      else extras << argument
      end
    end
    missing = %w[--target --identifier].reject { |name| options.key?(name.delete_prefix('--').to_sym) }
    raise UsageError, "the following arguments are required: #{missing.join(', ')}" unless missing.empty?
    raise UsageError, "unrecognized arguments: #{extras.join(' ')}" unless extras.empty?

    [options, nil]
  rescue UsageError => error
    stderr.print(USAGE, "\n")
    stderr.print("#{PROG}: error: #{error.message}", "\n")
    [options, 2]
  end

  def main(argv = ARGV, env: ENV, home: nil, stdout: $stdout, stderr: $stderr, runner: method(:run))
    options, status = parse_arguments(argv, stdout: stdout, stderr: stderr)
    return status if status

    source = development_book_source(env: env, home: home)
    if source.nil?
      stderr.print('ios development seed skipped: source EPUB is unavailable', "\n")
      return MISSING_SOURCE_EXIT
    end

    begin
      destination =
        if options[:target] == 'simulator'
          stage_for_simulator(source, options[:identifier], runner: runner)
        else
          stage_for_device(source, options[:identifier], runner: runner)
        end
    rescue CommandError => error
      message = error.stderr_text.strip
      stderr.print(message.empty? ? error.message : message, "\n")
      return 1
    rescue SystemCallError => error
      # Python surfaced a missing xcrun as an uncaught traceback (exit 1).
      stderr.print(error.message, "\n")
      return 1
    end

    stdout.print("ios development seed → #{File.basename(source)} → #{destination}", "\n")
    0
  end
end

exit SeedIosDevelopmentBook.main if $PROGRAM_NAME == __FILE__
