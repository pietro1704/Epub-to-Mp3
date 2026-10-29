#!/usr/bin/env ruby
# Retain device runtime bytes with their exact source and hosted build identity.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'package_converter_ffi_macos'

module ConverterFfiIOSPackage
  extend self
  INPUTS = %w[Cargo.toml Cargo.lock .cargo crates/converter-core crates/converter-ffi native
              mise.toml scripts/apple_target_clang.sh scripts/native_job.rb
              scripts/verify_converter_ffi_ios.sh scripts/package_converter_ffi_ios.rb
              scripts/package_converter_ffi_macos.rb .github/workflows/converter-ffi-ios-prebuilt.yml].freeze

  def command(*argv)
    ConverterFfiMacOSPackage.command(*argv)
  end

  def sources(root)
    paths = command('git', '-C', root, 'ls-files', '-z', '--', *INPUTS).split("\0").sort
    raise 'Missing build inputs' unless paths.include?('Cargo.toml')
    paths.to_h do |relative|
      path = File.join(root, relative)
      raise "Missing or symlinked source: #{relative}" unless File.file?(path) && !File.symlink?(path)
      [relative, Digest::SHA256.file(path).hexdigest]
    end
  end

  def inspect_native(root, library)
    command('env', "CONVERTER_FFI_IOS_ARTIFACT=#{library}", 'CONVERTER_FFI_IOS_ARCH=arm64',
            'CONVERTER_FFI_IOS_PLATFORM=2', 'CONVERTER_FFI_ENABLE_PIPER=1',
            'bash', File.join(root, 'scripts/verify_converter_ffi_ios.sh'))
    load_commands = command('xcrun', 'otool', '-l', library)
    minimum = load_commands[/\bminos\s+(\S+)/, 1]
    raise 'Runtime exceeds iOS 15.5' unless minimum && Gem::Version.new(minimum) <= Gem::Version.new('15.5')
    dependencies = command('xcrun', 'otool', '-L', library).lines.drop(2).map { |line| line.strip.split.first }
    raise 'Unexpected dynamic dependency' unless dependencies.all? { |path| path.start_with?('/System/Library/', '/usr/lib/') }
  end

  def verify(root, output, native: true)
    raise 'Package must be a plain directory' unless File.directory?(output) && !File.symlink?(output)
    files = ConverterFfiMacOSPackage.file_digests(output)
    receipt = JSON.parse(File.read(File.join(output, 'receipt.json')))
    raise 'Wrong package identity' unless receipt.values_at('schema', 'target', 'profile', 'features') ==
      [1, 'aarch64-apple-ios', 'release', ['piper-runtime']]
    raise 'Source mismatch' unless receipt.fetch('sources') == sources(root)
    raise 'Invalid producer' unless receipt.fetch('workflow') == 'converter-ffi-ios-prebuilt.yml' &&
      receipt.fetch('source_sha').match?(/\A[0-9a-f]{40}\z/) && receipt.fetch('run_id').match?(/\A[0-9]+\z/)
    raise 'Wrong Xcode' unless receipt.fetch('xcode').lines.first&.strip == 'Xcode 16.4'
    raise 'Wrong SDK' unless receipt.fetch('sdk') == '18.5'
    raise 'Payload mismatch' unless receipt.fetch('files') == files.reject { |name, _| name == 'receipt.json' }
    required = %w[libconverter_ffi.dylib espeak-ng-data/phontab espeak-ng-data/phondata]
    raise 'Incomplete package' unless (required - files.keys).empty?
    raise 'Unexpected file' unless files.keys.all? { |name| %w[receipt.json libconverter_ffi.dylib].include?(name) || name.start_with?('espeak-ng-data/') }
    inspect_native(root, File.join(output, 'libconverter_ffi.dylib')) if native
    receipt
  end

  def package(root, output)
    raise 'Hosted master dispatch required' unless ENV.values_at('GITHUB_EVENT_NAME', 'GITHUB_REF', 'RUNNER_ENVIRONMENT') ==
      ['workflow_dispatch', 'refs/heads/master', 'github-hosted']
    sha = command('git', '-C', root, 'rev-parse', 'HEAD').strip
    raise 'Unexpected checkout' unless sha == ENV.fetch('GITHUB_SHA')
    command('git', '-C', root, 'diff', '--exit-code', 'HEAD', '--', *INPUTS)
    raise 'Untracked input' unless command('git', '-C', root, 'ls-files', '-o', '--exclude-standard', '--', *INPUTS).empty?
    raise 'Output already exists' if File.exist?(output) || File.symlink?(output)
    data = Dir.glob(File.join(root, 'target/espeak-data/**/espeak-ng-data/phontab')).first
    raise 'Missing eSpeak data' unless data
    FileUtils.mkdir_p(output)
    FileUtils.cp(File.join(root, 'target/aarch64-apple-ios/release/libconverter_ffi.dylib'), output)
    FileUtils.cp_r(File.dirname(data), File.join(output, 'espeak-ng-data'))
    receipt = {
      'schema' => 1, 'target' => 'aarch64-apple-ios', 'profile' => 'release', 'features' => ['piper-runtime'],
      'source_sha' => sha, 'sources' => sources(root), 'workflow' => 'converter-ffi-ios-prebuilt.yml',
      'run_id' => ENV.fetch('GITHUB_RUN_ID'), 'run_attempt' => ENV.fetch('GITHUB_RUN_ATTEMPT'),
      'xcode' => command('xcodebuild', '-version'), 'rustc' => command('rustc', '-Vv'),
      'sdk' => command('xcrun', '--sdk', 'iphoneos', '--show-sdk-version').strip,
      'files' => ConverterFfiMacOSPackage.file_digests(output)
    }
    File.write(File.join(output, 'receipt.json'), JSON.pretty_generate(receipt) + "\n")
    verify(root, output)
  end
end

if $PROGRAM_NAME == __FILE__
  action, root, output = ARGV
  abort 'Usage: package_converter_ffi_ios.rb package|verify ROOT PACKAGE' unless ARGV.size == 3 && %w[package verify].include?(action)
  ConverterFfiIOSPackage.public_send(action, File.expand_path(root), File.expand_path(output))
  puts "iOS FFI package #{action} passed"
end
