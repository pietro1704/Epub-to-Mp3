#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'

# Inspect content even on no-op builds: missing or modified signed outputs must
# not hide behind a timestamp-only stamp. Keep unchanged resources intact.
root = File.expand_path('..', __dir__)
platform = ENV.fetch('PLATFORM_NAME')
exit 0 unless %w[macosx iphoneos iphonesimulator].include?(platform)
frameworks = File.join(ENV.fetch('TARGET_BUILD_DIR'), ENV.fetch('FRAMEWORKS_FOLDER_PATH'))
resources = File.join(ENV.fetch('TARGET_BUILD_DIR'), ENV.fetch('UNLOCALIZED_RESOURCES_FOLDER_PATH'))
receipt = File.join(ENV.fetch('DERIVED_FILE_DIR'), "speech-runtime-#{platform}.json")
scripts = %w[bundle_apple_runtime.rb bundle_converter_ffi_ios.sh verify_converter_ffi_ios.sh
             bundle_espeak_ng_data.sh bundle_onnxruntime_apple.sh prepare_onnxruntime_macos.rb
             fetch_onnxruntime_macos.rb].map { |name| File.join(root, 'scripts', name) }
arch = ENV.fetch('ARCHS', '')
target = platform == 'iphoneos' ? 'aarch64-apple-ios' :
  (arch == 'arm64' ? 'aarch64-apple-ios-sim' : 'x86_64-apple-ios')
profile = platform == 'iphonesimulator' && ENV['CONFIGURATION'] == 'Debug' ?
  ENV.fetch('CONVERTER_FFI_SIMULATOR_PROFILE', 'debug') : 'release'
ffi = platform == 'macosx' ? File.join(root, 'target/release/libconverter_ffi.dylib') :
  File.join(root, 'target', target, profile, 'libconverter_ffi.dylib')
runtime = if platform == 'macosx'
            File.join(root, 'target/onnxruntime-macos-prebuilt', arch, 'lib/libonnxruntime.dylib')
          else
            File.join(root, 'target/onnxruntime-ios15-src/build/iOS/Release/Release-iphonesimulator/libonnxruntime.1.24.2.dylib')
          end
phonemes = []
if ENV.fetch('CONVERTER_FFI_ENABLE_PIPER', '1') == '1'
  data_root = File.join(root, 'target/espeak-data')
  if File.directory?(data_root)
    found, error, status = Open3.capture3('find', data_root, '-path',
      '*/out/build/espeak-ng-data/phontab', '-type', 'f', '-print', '-quit')
    abort "Cannot inspect phonemizer data: #{error}" unless status.success?
    source = found.strip
    phonemes = Dir.glob(File.join(File.dirname(source), '**/*')).select { |path| File.file?(path) } unless source.empty?
  end
end
hashes = lambda do |files|
  files.sort.to_h { |path| [path, File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil] }
end
outputs = lambda do
  [File.join(frameworks, 'libconverter_ffi.dylib')] +
    Dir.glob(File.join(frameworks, 'libonnxruntime*.dylib')) +
    Dir.glob(File.join(resources, 'espeak-ng-data/**/*')).select { |path| File.file?(path) }
end
verify_signatures = lambda do
  Dir.glob(File.join(frameworks, '{libconverter_ffi,libonnxruntime*}.dylib')).each do |library|
    abort "Invalid runtime signature: #{library}" unless system('codesign', '--verify', '--strict', library)
  end
end
signature = {
  'inputs' => hashes.call(scripts + [ffi, runtime] + phonemes),
  'environment' => %w[PLATFORM_NAME ARCHS CONFIGURATION EXPANDED_CODE_SIGN_IDENTITY
    CODE_SIGNING_ALLOWED CONVERTER_FFI_ENABLE_PIPER CONVERTER_FFI_SIMULATOR_PROFILE
    CONVERTER_FFI_BUILD_ALWAYS DEVELOPER_DIR].to_h { |key| [key, ENV[key]] }
}
previous = begin
  JSON.parse(File.read(receipt))
rescue Errno::ENOENT, JSON::ParserError
  nil
end
if ENV['CONVERTER_FFI_BUILD_ALWAYS'] != '1' && previous && previous['signature'] == signature &&
   previous['outputs'] == hashes.call(outputs.call) && File.file?(File.join(frameworks, 'libconverter_ffi.dylib'))
  verify_signatures.call
  puts 'Native speech packaging cache hit; signed libraries and phonemizer data unchanged.'
  exit 0
end
if platform == 'macosx'
  actual_arch, error, status = Open3.capture3('xcrun', 'lipo', '-archs', ffi)
  abort "Wrong macOS converter architecture: #{actual_arch.strip} (expected #{arch}): #{error}" unless
    status.success? && %w[x86_64 arm64].include?(arch) && actual_arch.strip == arch
  FileUtils.mkdir_p(frameworks)
  embedded = File.join(frameworks, 'libconverter_ffi.dylib')
  FileUtils.cp(ffi, embedded)
  identity = ENV['EXPANDED_CODE_SIGN_IDENTITY'].to_s
  identity = '-' if identity.empty?
  abort 'Cannot sign copied macOS converter' unless system('codesign', '--force', '--sign', identity, embedded)
end
%w[bundle_converter_ffi_ios.sh bundle_espeak_ng_data.sh bundle_onnxruntime_apple.sh].each do |script|
  abort "Native speech packaging failed: #{script}" unless system('bash', File.join(root, 'scripts', script))
end
abort 'Missing embedded converter-ffi' unless File.file?(File.join(frameworks, 'libconverter_ffi.dylib'))
verify_signatures.call
FileUtils.mkdir_p(File.dirname(receipt))
temporary = "#{receipt}.#{Process.pid}.tmp"
File.write(temporary, JSON.generate('signature' => signature, 'outputs' => hashes.call(outputs.call)))
File.rename(temporary, receipt)
puts 'Native speech packaging cache refreshed.'
