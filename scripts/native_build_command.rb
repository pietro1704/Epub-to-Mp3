#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'native_job'

lock_path = NativeJob::LOCK_PATH
build_dirs = []
parser = OptionParser.new do |opts|
  opts.banner = 'Usage: native_build_command.rb [--lock-path PATH] [--build-dir PATH] [--] COMMAND [ARGUMENTS]'
  opts.on('--lock-path PATH') { |value| lock_path = value }
  opts.on('--build-dir PATH') { |value| build_dirs << value }
end
begin
  parser.order!(ARGV)
rescue OptionParser::ParseError => error
  abort error.message
end
abort parser.to_s if ARGV.empty?

if Gem.win_platform?
  # These task bodies previously used this lock and system on Windows. Keep
  # that behavior; the POSIX supervisor is not a Windows process-group adapter.
  lease = File.open(lock_path, 'a+')
  abort 'Another heavy job is active' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
  exit(system(*ARGV) ? 0 : ($?.exitstatus || 1))
end

exit NativeJob.run(phase: 'build', command: ARGV, path: lock_path, build_dir: build_dirs)
