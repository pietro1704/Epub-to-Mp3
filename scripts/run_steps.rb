# frozen_string_literal: true

require "json"
require "time"

# Execute argv steps, retaining exact output and the first unsuccessful status.
module RunSteps
  PREVIEW_BYTES = 2_048

  def self.preview(path)
    File.open(path, "rb") do |file|
      file.seek([file.size - PREVIEW_BYTES, 0].max)
      file.read.force_encoding(Encoding::UTF_8).scrub
    end
  end

  def self.validate(plan)
    raise ArgumentError, "cwd must name an existing directory" unless plan.is_a?(Hash) && plan["cwd"].is_a?(String) && File.directory?(plan["cwd"])
    steps = plan["steps"]
    raise ArgumentError, "steps must be a nonempty array" unless steps.is_a?(Array) && !steps.empty?
    steps.each do |step|
      argv = step.is_a?(Hash) && step["argv"]
      unless argv.is_a?(Array) && !argv.empty? && argv.all? { |arg| arg.is_a?(String) && !arg.include?("\0") } && !argv.first.empty?
        raise ArgumentError, "every step requires literal argv strings"
      end
      timeout = step.fetch("timeout_seconds", 120)
      raise ArgumentError, "timeout_seconds must be positive and finite" unless timeout.is_a?(Numeric) && timeout.positive? && timeout.finite?
    end
  end

  def self.execute(argv, cwd, stdout, stderr, timeout)
    cancelled = nil
    child = nil
    previous = {}
    %w[INT TERM].each { |signal| previous[signal] = Signal.trap(signal) { cancelled = Signal.list.fetch(signal) } }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    File.write(stdout, "")
    File.write(stderr, "")
    child = Process.spawn([argv.first, argv.first], *argv.drop(1), chdir: cwd, out: stdout, err: stderr, pgroup: true)
    stopping_at = nil
    timed_out = false
    loop do
      _, status = Process.waitpid2(child, Process::WNOHANG)
      if status
        Process.kill("KILL", -child) rescue Errno::ESRCH if cancelled || timed_out || !status.success?
        code = cancelled ? 128 + cancelled : timed_out ? 124 : status.exitstatus || 128 + status.termsig
        return [code, status.termsig]
      end

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      timed_out ||= now - started >= timeout
      if (cancelled || timed_out) && !stopping_at
        Process.kill(cancelled || "TERM", -child) rescue Errno::ESRCH
        stopping_at = now
      elsif stopping_at && now - stopping_at >= 1
        Process.kill("KILL", -child) rescue Errno::ESRCH
      end
      sleep 0.01
    end
  rescue SystemCallError => error
    File.open(stderr, "a") { |file| file.puts("#{error.class}: #{error.message}") }
    [127, nil]
  ensure
    previous&.each { |signal, handler| Signal.trap(signal, handler) }
  end

  def self.run(plan_path, directory)
    plan = JSON.parse(File.read(plan_path))
    validate(plan)
    directory = File.expand_path(directory)
    Dir.mkdir(directory, 0o700) # An existing output directory must never be overwritten.
    report = { "cwd" => File.realpath(plan.fetch("cwd")), "started_at" => Time.now.utc.iso8601, "steps" => [], "exit_code" => 0 }
    plan.fetch("steps").each_with_index do |step, index|
      prefix = format("%03d", index + 1)
      stdout = File.join(directory, "#{prefix}.stdout")
      stderr = File.join(directory, "#{prefix}.stderr")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      code, signal = execute(step.fetch("argv"), report.fetch("cwd"), stdout, stderr, step.fetch("timeout_seconds", 120))
      report["steps"] << { "name" => step.fetch("name", prefix), "argv" => step.fetch("argv"), "exit_code" => code,
                            "signal" => signal, "duration_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
                            "stdout" => stdout, "stderr" => stderr }
      report["exit_code"] = code
      puts "#{prefix}: exit=#{code}; exact output: #{stdout}, #{stderr}"
      [stdout, stderr].each { |path| print preview(path) }
      break unless code.zero?
    end
    File.write(File.join(directory, "report.json"), JSON.pretty_generate(report) + "\n")
    report.fetch("exit_code")
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise ArgumentError, "Usage: run_steps.rb PLAN.json NEW_OUTPUT_DIRECTORY" unless ARGV.length == 2
    exit RunSteps.run(*ARGV)
  rescue ArgumentError, JSON::ParserError, SystemCallError => error
    warn error.message
    exit 2
  end
end
