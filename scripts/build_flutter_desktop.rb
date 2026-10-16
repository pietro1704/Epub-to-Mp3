#!/usr/bin/env ruby
require "tmpdir"

platform = ARGV.fetch(0)
abort "Expected a Linux or Windows desktop target" unless %w[linux windows].include?(platform)
root = File.expand_path("..", __dir__)
lock_directory = Gem.win_platform? ? Dir.tmpdir : "/tmp"
lease = File.open(File.join(lock_directory, "epub2mp3.heavy-job.lock"), "a+")
abort "Another heavy job is active" unless lease.flock(File::LOCK_EX | File::LOCK_NB)
Dir.chdir(File.join(root, "flutter_app")) do
  success = system({ "CMAKE_BUILD_PARALLEL_LEVEL" => "1", "CARGO_BUILD_JOBS" => "1" },
    "mise", "exec", "--", "flutter", "build", platform, "--release")
  exit(success ? 0 : ($?.exitstatus || 1))
end
