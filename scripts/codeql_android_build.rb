# frozen_string_literal: true

require "open3"

module CodeqlAndroidBuild
  RETRY_DELAYS = [30, 90].freeze
  MAVEN_CENTRAL_THROTTLED = %r{Could not (?:GET|HEAD) 'https://repo\.maven\.apache\.org/maven2/[^']+'\. Received status code 429 from server:}

  def self.run(command, sleeper: Kernel.method(:sleep))
    (RETRY_DELAYS.length + 1).times do |attempt|
      throttled = false
      status = Open3.popen2e(*command) do |input, output, process|
        input.close
        output.each_line do |line|
          $stdout.write(line)
          throttled ||= MAVEN_CENTRAL_THROTTLED.match?(line)
        end
        process.value
      end
      return 128 + status.termsig if status.signaled?

      delay = RETRY_DELAYS[attempt]
      return status.exitstatus if status.success? || !throttled || delay.nil?

      warn "Maven Central rate-limited the Android build. Retrying in #{delay} s."
      sleeper.call(delay)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  ARGV.shift if ARGV.first == "--"
  abort "Usage: ruby scripts/codeql_android_build.rb -- COMMAND [ARG ...]" if ARGV.empty?
  $stdout.sync = true
  exit CodeqlAndroidBuild.run(ARGV)
end
