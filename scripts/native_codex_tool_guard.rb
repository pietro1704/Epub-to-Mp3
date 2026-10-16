#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"

# A bounded recognizer of known native entry points, not a shell parser/sandbox.
module NativeCodexToolGuard
  REASON = "Local native execution is quarantined; use GitHub validation. Inspection and shutdown remain available."
  INSPECTION = %w[rg grep sed cat head tail less git ls find stat file pgrep ps readlink realpath].freeze
  QUERIES = %w[-version -list -showsdks -showdestinations -showBuildSettings].freeze
  NATIVE_TASKS = %w[
    converter-ffi:build native-tts:rust:test converter-ffi:ios-device
    converter-ffi:ios-device:verify converter-ffi:ios-simulator
    converter-ffi:ios-packaging:test apple:chapter-callback:test
    mac:build mac:build:dev mac:run ios:build ios:device:run ios:device:build
    ios:run ios:simulator:smoke:build ios:simulator:smoke:test ios:simulator:run
    ios:simulator:resume ios:simulator:test ios:device:test ios:device:benchmark
    ios:device:workflow:test apple:foundation:test apple:foundation:ffi:test
    ios:test flutter:run flutter:test flutter:run-desktop
  ].freeze

  # Discard quoted literal data, retaining active command substitutions. This
  # deliberately bounded scan does not expand shell syntax or execute anything.
  def self.active_code(command)
    output = +""
    quote = nil
    substitutions = []
    index = 0
    while index < command.length
      character = command[index]
      if character == "\\" && quote != "'"
        output << " "
        index += 2
        next
      end
      if quote == "'"
        quote = nil if character == "'"
      elsif character == "'" && quote.nil?
        quote = "'"
        output << " "
      elsif character == '"'
        quote = quote == '"' ? nil : '"'
        output << " "
      elsif character == "$" && command[index + 1] == "("
        substitutions << [quote, ")"]
        quote = nil
        output << ";"
        index += 1
      elsif character == "`"
        if substitutions.last&.last == "`"
          quote = substitutions.pop.first
        else
          substitutions << [quote, "`"]
          quote = nil
        end
        output << ";"
      elsif character == ")" && substitutions.last&.last == ")" && quote.nil?
        quote = substitutions.pop.first
        output << ";"
      elsif quote.nil?
        output << character
      end
      index += 1
    end
    output
  end

  def self.query_only?(arguments)
    query = false
    pending_value = false
    arguments.each do |argument|
      if pending_value
        pending_value = false
      elsif QUERIES.include?(argument)
        query = true
      elsif %w[-project -workspace -scheme -sdk -destination -configuration].include?(argument)
        pending_value = true
      else
        return false
      end
    end
    query && !pending_value
  end

  def self.blocked?(command, tty: false)
    return true if tty
    tokens = Shellwords.split(command)
    return false if tokens.empty?
    active = active_code(command)
    complex = active.match?(/[;\n|&<>]/)
    if complex && active.match?(%r{(?:\A|[\s;/|&()])(?:xcodebuild|simctl|swiftc|swift|flutter|Simulator|SimMetalHost|EpubToMp3|native_job\.rb)(?=[\s;|&()]|\z)})
      return true
    end
    return true if complex && NATIVE_TASKS.any? { |task| active.include?(task) }
    return true if complex && active.match?(/apple-(?:ios|darwin)/)
    names = tokens.map { |token| File.basename(token) }
    return false if !complex && INSPECTION.include?(names.first)
    return false if !complex && %w[echo printf].include?(names.first)
    return true if %w[bash sh zsh fish].include?(names.first) && (tokens.length == 1 || tokens.include?("-i"))
    return false if !complex && tokens == ["osascript", "-e", 'tell application "Simulator" to quit']

    tokens.each_index do |index|
      name = names[index]
      following = tokens.drop(index + 1)
      case name
      when "bash", "sh", "zsh", "fish"
        return true if following.empty? || following.any? { |arg| arg.match?(/\A-[^-]*i/) }
        shell_command = following.each_index.find { |position| following[position].match?(/\A-[^-]*c/) }
        return true if shell_command && blocked?(following.fetch(shell_command + 1))
        return true if !shell_command && following.all? { |arg| arg.start_with?("-") }
      when "xcodebuild"
        return true if complex || !query_only?(following)
      when "simctl"
        return true unless !complex && %w[list help shutdown terminate].include?(following.first)
      when "Simulator", "SimMetalHost", "EpubToMp3", "swiftc"
        return true
      when "open"
        return true if following.any? { |arg| arg.match?(/Simulator(?:\.app)?\z|EpubToMp3\.app(?:\/|\z)/i) }
      when "swift"
        return true unless !complex && following == ["--version"]
      when "native_job.rb"
        return true if (following & %w[build simulator]).any?
      when "flutter"
        return true if (following & %w[build run test drive]).any?
      when "cargo"
        return true if following.any? { |arg| arg.match?(/apple-(?:ios|darwin)/) }
      when "mise"
        return true if (following & NATIVE_TASKS).any?
      end
    end
    false
  rescue ArgumentError
    true
  end

  def self.in_scope?(cwd, expected)
    output, status = Open3.capture2e(
      { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil },
      "git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"
    )
    raise "Cannot inspect repository scope" unless status.success?
    File.realpath(output.strip) == File.realpath(expected)
  end

  def self.main(input, expected)
    payload = JSON.parse(input)
    raise ArgumentError unless payload.is_a?(Hash) && payload["hook_event_name"] == "PreToolUse"
    tool = payload.fetch("tool_name")
    return nil unless %w[Bash exec_command].include?(tool)
    arguments = payload.fetch("tool_input")
    raise ArgumentError unless arguments.is_a?(Hash)
    command = arguments["command"] || arguments["cmd"]
    raise ArgumentError unless command.is_a?(String)
    raise ArgumentError if arguments.key?("command") && arguments.key?("cmd") && arguments["command"] != arguments["cmd"]
    return nil unless blocked?(command, tty: arguments["tty"] == true)
    session_cwd = payload.fetch("cwd")
    workdir = arguments["workdir"] || session_cwd
    raise ArgumentError unless session_cwd.is_a?(String) && workdir.is_a?(String) && expected.is_a?(String)
    return nil unless in_scope?(session_cwd, expected) || in_scope?(workdir, expected)
    denial
  rescue StandardError
    denial
  end

  def self.denial
    { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: REASON } }
  end
end

if $PROGRAM_NAME == __FILE__
  result = NativeCodexToolGuard.main($stdin.read, ARGV.fetch(0, nil))
  puts JSON.generate(result) if result
end
