#!/usr/bin/env ruby
require_relative 'native_job'
if Gem.win_platform?
  lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
  abort 'Another heavy job is active' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
else
  NativeJob.build_entrypoint(__FILE__, ARGV)
end
require "fileutils"
require_relative "native_job"
NativeJob.build_entrypoint(__FILE__, ARGV)
if RUBY_PLATFORM.include?("darwin")
  runtime = IO.popen(["mise", "exec", "--", "ruby", "scripts/prepare_onnxruntime_macos.rb"], NativeJob.child_options, &:read).strip
  abort "Failed to prepare Intel ONNX Runtime" unless $?.success? && runtime.start_with?("/")
  ENV["ORT_LIB_LOCATION"] = runtime
  ENV["ORT_PREFER_DYNAMIC_LINK"] = "1"
  ENV["MACOSX_DEPLOYMENT_TARGET"] = "12.0"
  ENV.delete("SDKROOT")
  ENV["DYLD_LIBRARY_PATH"] = runtime
  ["target/debug", "target/debug/deps"].each do |directory|
    FileUtils.mkdir_p(directory)
    Dir.glob(File.join(runtime, "libonnxruntime*.dylib")).each { |library| FileUtils.cp(library, directory) }
  end
end
commands = [
  %w[cargo test -p converter-core --lib tts_preferences --jobs 1],
  %w[cargo test -p converter-core --lib a_voice_is_installed_only_with_both_verified_artifacts --jobs 1],
  %w[cargo test -p converter-core --lib worker::tests --jobs 1],
  %w[cargo test -p converter-ffi --lib typed_preferences --features android-jni --jobs 1],
  %w[cargo test -p converter-ffi --lib controlled_typed_options --features android-jni --jobs 1],
  %w[cargo test -p converter-ffi --lib queued_streaming_ --features android-jni --jobs 1],
  %w[cargo test -p converter-ffi --lib opaque_tts_policy_state --features android-jni --jobs 1],
  %w[cargo test -p converter-cli --jobs 1],
  %w[cargo test -p converter-server typed_http_ --jobs 1 -- --test-threads=1]
]
if (resume = ENV["TTS_PREFERENCES_FROM"])
  index = commands.index { |command| command.include?(resume) }
  abort "Unknown TTS verification checkpoint: #{resume}" unless index
  commands = commands.drop(index)
end
commands.each do |command|
  exit($?.exitstatus || 1) unless system("mise", "exec", "--", *command, **NativeJob.child_options)
end
