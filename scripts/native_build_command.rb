#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'native_job'

ARGV.shift if ARGV.first == '--'
abort 'Usage: native_build_command.rb [--] COMMAND [ARGUMENTS]' if ARGV.empty?

if Gem.win_platform?
  # These task bodies previously used this lock and system on Windows. Keep
  # that behavior; the POSIX supervisor is not a Windows process-group adapter.
  lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
  abort 'Another heavy job is active' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
  exit(system(*ARGV) ? 0 : ($?.exitstatus || 1))
end

exit NativeJob.run(phase: 'build', command: ARGV)
