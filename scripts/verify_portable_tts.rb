#!/usr/bin/env ruby
require_relative 'native_job'
if Gem.win_platform?
  lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
  abort 'Another heavy job is active' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
else
  NativeJob.build_entrypoint(__FILE__, ARGV)
end
require "fileutils"
directory = ".reports/tts-preferences/checks"
FileUtils.mkdir_p(directory)
commands = [
  ["codec", %w[mise exec -- cargo test -p converter-core --lib pcm::tests --jobs 1]],
  ["wasm", %w[mise run web:wasm-build]],
  ["web", %w[mise run test:web]],
  ["browser-storage", %w[mise exec -- node web/scripts/verify-browser-store.mjs]],
  ["browser", %w[mise exec -- node web/scripts/verify-browser-tts.mjs]],
  ["browser-production", %w[env TTS_BROWSER_MODE=production mise exec -- node web/scripts/verify-browser-tts.mjs]],
  ["flutter-analyze", %w[mise run flutter:analyze]],
  ["flutter-tests", %w[mise run flutter:test]]
]
if (stage = ENV["TTS_PORTABLE_FROM"])
  abort "Unknown portable verification stage: #{stage}" unless commands.any? { |name, _| name == stage }
  commands = commands.drop_while { |name, _| name != stage }
end
commands.each do |name, command|
  path = File.join(directory, "#{name}.log")
  puts "Running #{name}; evidence: #{path}"
  STDOUT.flush
  success = File.open(path, "w") { |log| system(*command, out: log, err: log, **NativeJob.child_options) }
  unless success
    warn File.readlines(path).last(45).join
    exit($?.exitstatus || 1)
  end
  puts "Passed #{name}"
end
