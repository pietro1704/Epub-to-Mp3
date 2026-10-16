#!/usr/bin/env ruby
require "tmpdir"
unless Gem.win_platform?
  require_relative 'native_job'
  NativeJob.build_entrypoint(__FILE__, ARGV)
end

platform = ARGV.fetch(0)
abort "Expected a Linux or Windows desktop target" unless %w[linux windows].include?(platform)
root = File.expand_path("..", __dir__)
if Gem.win_platform?
  # Preserve the existing temporary-directory lease without POSIX supervision.
  lease = File.open(File.join(Dir.tmpdir, "epub2mp3.heavy-job.lock"), "a+")
  abort "Another heavy job is active" unless lease.flock(File::LOCK_EX | File::LOCK_NB)
end
Dir.chdir(File.join(root, "flutter_app")) do
  success = system({ "CMAKE_BUILD_PARALLEL_LEVEL" => "1", "CARGO_BUILD_JOBS" => "1" },
    "mise", "exec", "--", "flutter", "build", platform, "--release",
    **(Gem.win_platform? ? {} : NativeJob.child_options))
  exit(success ? 0 : ($?.exitstatus || 1))
end
