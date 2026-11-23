#!/usr/bin/env ruby
require "etc"
require "tmpdir"
unless Gem.win_platform?
  require_relative 'native_job'
  NativeJob.build_entrypoint(__FILE__, ARGV, build_dir: File.expand_path('../flutter_app/build', __dir__))
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
  # Linux keeps the lease-supervised single job. Windows has no supervisor, so a
  # GitHub-hosted runner (a disposable VM) may use up to four jobs.
  hosted = ENV["GITHUB_ACTIONS"] == "true" && ENV["RUNNER_ENVIRONMENT"] == "github-hosted" && !ENV["ImageOS"].to_s.empty?
  jobs = Gem.win_platform? && hosted ? Etc.nprocessors.clamp(1, 4).to_s : "1"
  success = system({ "CMAKE_BUILD_PARALLEL_LEVEL" => jobs, "CARGO_BUILD_JOBS" => jobs },
    "mise", "exec", "--", "flutter", "build", platform, "--release",
    **(Gem.win_platform? ? {} : NativeJob.child_options))
  exit(success ? 0 : ($?.exitstatus || 1))
end
