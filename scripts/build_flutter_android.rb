#!/usr/bin/env ruby
# Native packaging is a task dependency; keep the APK build/audit under one lease.
require 'rbconfig'

root = File.expand_path('..', __dir__)
Dir.chdir(root)
mode = ARGV.first || 'release'
abort 'Expected debug or release' unless %w[debug release].include?(mode)
lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
abort 'Another heavy job is active' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
packager = File.join(root, 'scripts/package_converter_ffi_android.rb')
exit($?.exitstatus || 1) unless system(RbConfig.ruby, packager, '--audit')
Dir.chdir(File.join(root, 'flutter_app')) do
  if ARGV.include?('--clean')
    exit($?.exitstatus || 1) unless system('mise', 'exec', '--', 'flutter', 'clean')
  end
  exit($?.exitstatus || 1) unless system('mise', 'exec', '--', 'flutter', 'pub', 'get')
  command = ['mise', 'exec', '--', 'flutter', 'build', 'apk', "--#{mode}", '--target-platform', 'android-arm64', '--no-pub']
  command << "--build-number=#{ENV['FLUTTER_BUILD_NUMBER']}" if ENV['FLUTTER_BUILD_NUMBER']
  exit($?.exitstatus || 1) unless system(*command)
end
apk = File.join(root, 'flutter_app/build/app/outputs/flutter-apk', "app-#{mode}.apk")
exit($?.exitstatus || 1) unless system(RbConfig.ruby, packager, '--audit', '--apk', apk)
