#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'native_job'

lock_path = NativeJob::LOCK_PATH
if ARGV.first == '--lock-path'
  ARGV.shift
  lock_path = ARGV.shift
  abort 'Usage: native_build_command.rb [--lock-path PATH] [--] COMMAND [ARGUMENTS]' if lock_path.nil? || lock_path.empty?
end
ARGV.shift if ARGV.first == '--'
abort 'Usage: native_build_command.rb [--lock-path PATH] [--] COMMAND [ARGUMENTS]' if ARGV.empty?

if Gem.win_platform?
  # These task bodies previously used this lock and system on Windows. Keep
  # that behavior; the POSIX supervisor is not a Windows process-group adapter.
  lease = File.open(lock_path, 'a+')
  abort 'Another heavy job is active' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
  exit(system(*ARGV) ? 0 : ($?.exitstatus || 1))
end

exit NativeJob.run(phase: 'build', command: ARGV, path: lock_path)
