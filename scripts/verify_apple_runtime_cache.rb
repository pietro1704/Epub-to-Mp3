#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# Exercise packaging with the existing real macOS runtime. Never compile,
# download a dependency, launch an app, or modify the original libraries.
root = File.realpath(File.expand_path('..', __dir__))
converter = File.join(root, 'target/release/libconverter_ffi.dylib')
abort 'Build or supply the verified macOS converter before running this check' unless File.file?(converter)
architecture, error, status = Open3.capture3('xcrun', 'lipo', '-archs', converter)
architecture = architecture.strip
abort "Expected one macOS architecture: #{architecture}: #{error}" unless
  status.success? && %w[x86_64 arm64].include?(architecture)
runtime = File.join(root, 'target/onnxruntime-macos-prebuilt', architecture, 'lib/libonnxruntime.dylib')
sources = [converter, runtime].select { |path| File.file?(path) }
original_hashes = sources.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
report = {}

begin
  Dir.mktmpdir('epub-runtime-cache-') do |temporary|
    fixture = File.realpath(temporary)
    frameworks = File.join(fixture, 'Fixture.app/Contents/Frameworks')
    environment = {
      'PLATFORM_NAME' => 'macosx', 'ARCHS' => architecture, 'CONFIGURATION' => 'Debug',
      'TARGET_BUILD_DIR' => fixture,
      'FRAMEWORKS_FOLDER_PATH' => 'Fixture.app/Contents/Frameworks',
      'UNLOCALIZED_RESOURCES_FOLDER_PATH' => 'Fixture.app/Contents/Resources',
      'DERIVED_FILE_DIR' => File.join(fixture, 'Derived'),
      'SRCROOT' => File.join(root, 'ios/EpubToMp3'),
      'EXPANDED_CODE_SIGN_IDENTITY' => '-', 'CODE_SIGNING_ALLOWED' => 'NO',
      'CONVERTER_FFI_BUILD_ALWAYS' => '0', 'CONVERTER_FFI_ENABLE_PIPER' => '1'
    }
    package = lambda do |name, overrides = {}, succeeds = true|
      output, diagnostic, result = Open3.capture3(
        environment.merge(overrides), RbConfig.ruby,
        File.join(root, 'scripts/bundle_apple_runtime.rb')
      )
      report[name] = { 'exit_status' => result.exitstatus, 'output' => output }
      abort "Unexpected #{name} packaging result: #{output}\n#{diagnostic}" unless
        result.success? == succeeds
      unless succeeds
        rejected_identity = diagnostic.include?('Wrong macOS converter architecture:')
        abort "Identity check failed for another reason: #{diagnostic}" unless rejected_identity
        report[name]['identity_rejected'] = true
      end
      output
    end

    abort 'Cold package did not populate the cache' unless package.call('cold').include?('cache refreshed')
    embedded = File.join(frameworks, 'libconverter_ffi.dylib')
    expected_hash = Digest::SHA256.file(embedded).hexdigest
    expected_mtime = File.mtime(embedded)
    abort 'Warm package missed the cache' unless package.call('warm').include?('cache hit')
    abort 'Warm package rewrote the converter' unless File.mtime(embedded) == expected_mtime

    File.open(embedded, 'ab') { |file| file.write('invalid-cache-output') }
    abort 'Tampered output was reused' unless package.call('repair').include?('cache refreshed')
    abort 'Repair did not restore the signed converter' unless
      Digest::SHA256.file(embedded).hexdigest == expected_hash
    abort 'Repaired package missed the cache' unless package.call('warm_after_repair').include?('cache hit')

    other_architecture = architecture == 'arm64' ? 'x86_64' : 'arm64'
    package.call('reject_wrong_architecture', { 'ARCHS' => other_architecture }, false)
    abort 'Rejected identity modified the package' unless
      Digest::SHA256.file(embedded).hexdigest == expected_hash
  end
ensure
  original_hashes.each do |path, digest|
    abort "Original runtime changed: #{path}" unless Digest::SHA256.file(path).hexdigest == digest
  end
end

puts JSON.pretty_generate('architecture' => architecture, 'checks' => report, 'originals_unchanged' => true)
