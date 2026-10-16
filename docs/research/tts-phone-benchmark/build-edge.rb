# frozen_string_literal: true
require_relative '../../../scripts/native_job'
NativeJob.build_entrypoint(__FILE__, ARGV)
require 'fileutils'
root = File.expand_path('../../..', __dir__)
downloads = File.join(root, '.reports/tts-six/20261014/downloads')
crate = File.join(downloads, 'edge-probe')
FileUtils.mkdir_p(File.join(crate, 'src'))
FileUtils.cp(File.join(__dir__, 'EdgeProbe.rs'), File.join(crate, 'src/lib.rs'))
File.write(File.join(crate, 'Cargo.toml'), <<~TOML)
  [package]
  name = "tts-phone-edge-probe"
  version = "0.1.0"
  edition = "2021"
  [workspace]
  [lib]
  crate-type = ["staticlib"]
  [dependencies]
  converter-core = { path = "#{root}/crates/converter-core" }
  tokio = { version = "1", features = ["rt", "time"] }
TOML
FileUtils.cp(File.join(root, 'Cargo.lock'), File.join(crate, 'Cargo.lock'))
  command = ['env', 'DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer', 'IPHONEOS_DEPLOYMENT_TARGET=15.0', 'mise', 'exec', '--', 'cargo', 'build', '--manifest-path', File.join(crate, 'Cargo.toml'), '--release', '--target', 'aarch64-apple-ios', '--target-dir', File.join(downloads, 'edge-build'), '--jobs', '1']
  abort 'Rust Edge probe build failed' unless system(*command)
