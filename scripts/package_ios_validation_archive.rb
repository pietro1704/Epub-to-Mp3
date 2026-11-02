#!/usr/bin/env ruby
# An unsigned app archive for explicit device validation, never a release artifact.
require_relative 'package_converter_ffi_ios'

module IOSValidationArchive
  extend self
  APP_INPUTS = %w[ios/EpubToMp3/EpubToMp3 ios/EpubToMp3/EpubToMp3Widget
                  ios/EpubToMp3/EpubToMp3ShareExtension ios/EpubToMp3/project.yml
                  scripts/package_ios_validation_archive.rb scripts/bundle_converter_ffi_ios.sh
                  scripts/bundle_espeak_ng_data.sh].freeze

  def sources(root)
    untracked = ConverterFfiIOSPackage.command('git', '-C', root, 'ls-files', '-o', '--exclude-standard', '--', *ConverterFfiIOSPackage::INPUTS, *APP_INPUTS)
    raise 'Untracked build inputs' unless untracked.empty?
    paths = ConverterFfiIOSPackage.command('git', '-C', root, 'ls-files', '-z', '--', *APP_INPUTS).split("\0")
    ConverterFfiIOSPackage.sources(root).merge(paths.sort.to_h do |relative|
      path = File.join(root, relative)
      raise "Invalid source: #{relative}" unless File.file?(path) && !File.symlink?(path)
      [relative, Digest::SHA256.file(path).hexdigest]
    end).sort.to_h
  end

  def identity(root)
    Digest::SHA256.hexdigest(JSON.generate(sources(root)))
  end

  def inspect_native(root, archive)
    app = File.join(archive, 'Products/Applications/EpubToMp3.app')
    identifier = ConverterFfiIOSPackage.command('plutil', '-extract', 'CFBundleIdentifier', 'raw', '-o', '-', File.join(app, 'Info.plist')).strip
    raise 'Wrong application identity' unless identifier == 'com.pietrocode.epubtomp3'
    minimum = ConverterFfiIOSPackage.command('plutil', '-extract', 'MinimumOSVersion', 'raw', '-o', '-', File.join(app, 'Info.plist')).strip
    raise 'Application exceeds iOS 15.5' unless Gem::Version.new(minimum) <= Gem::Version.new('15.5')
    plugins = Dir.glob(File.join(app, 'PlugIns/*.appex'))
    raise 'Missing embedded extensions' unless plugins.map { |path| File.basename(path) }.sort == %w[EpubToMp3ShareExtension.appex EpubToMp3Widget.appex]
    executables = [File.join(app, 'EpubToMp3')] + plugins.map { |path| File.join(path, File.basename(path, '.appex')) }
    executables.each do |path|
      raise 'Wrong device architecture' unless ConverterFfiIOSPackage.command('lipo', '-archs', path).strip == 'arm64'
      commands = ConverterFfiIOSPackage.command('otool', '-l', path)
      raise 'Wrong device platform' unless commands.match?(/LC_BUILD_VERSION\s+cmdsize\s+\d+\s+platform\s+2\b/)
    end
    ConverterFfiIOSPackage.inspect_native(root, File.join(app, 'Frameworks/libconverter_ffi.dylib'))
    %w[phontab phondata].each do |name|
      raise 'Missing phonemizer assets' unless File.file?(File.join(app, 'espeak-ng-data', name))
    end
  end

  def write_receipt(root, output, expected_identity, provenance:)
    raise 'Sources changed during archive' unless identity(root) == expected_identity
    raise 'Wrong checkout identity' unless provenance.fetch('source_sha') == ConverterFfiIOSPackage.command('git', '-C', root, 'rev-parse', 'HEAD').strip
    payload = File.join(output, 'EpubToMp3.xcarchive.zip')
    raise 'Missing or symlinked archive' unless File.file?(payload) && !File.symlink?(payload)
    receipt = provenance.merge('schema' => 1, 'kind' => 'unsigned-ios-validation-archive',
      'identity_sha256' => expected_identity, 'sources' => sources(root),
      'archive_sha256' => Digest::SHA256.file(payload).hexdigest)
    File.write(File.join(output, 'receipt.json'), JSON.pretty_generate(receipt) + "\n")
    receipt
  end

  def verify(root, output)
    raise 'Invalid package directory' unless File.directory?(output) && !File.symlink?(output)
    raise 'Symlinked receipt' if File.symlink?(File.join(output, 'receipt.json'))
    receipt = JSON.parse(File.read(File.join(output, 'receipt.json')))
    raise 'Wrong artifact kind' unless receipt.values_at('schema', 'kind') == [1, 'unsigned-ios-validation-archive']
    raise 'Wrong checkout identity' unless receipt.fetch('source_sha') == ConverterFfiIOSPackage.command('git', '-C', root, 'rev-parse', 'HEAD').strip
    raise 'Invalid producer' unless receipt.values_at('workflow', 'mode') == ['converter-ffi-ios-prebuilt.yml', 'build_app_only'] &&
      receipt.fetch('repository').match?(/\A[\w.-]+\/[\w.-]+\z/) && %w[run_id run_attempt].all? { |key| receipt.fetch(key).match?(/\A[1-9][0-9]*\z/) }
    raise 'Source mismatch' unless receipt.fetch('identity_sha256') == identity(root) && receipt.fetch('sources') == sources(root)
    payload = File.join(output, 'EpubToMp3.xcarchive.zip')
    raise 'Archive mismatch' unless File.file?(payload) && !File.symlink?(payload) && Digest::SHA256.file(payload).hexdigest == receipt.fetch('archive_sha256')
    receipt
  end

  def package(root, archive, output, expected_identity)
    raise 'Hosted branch dispatch required' unless ENV.values_at('GITHUB_EVENT_NAME', 'RUNNER_ENVIRONMENT') == ['workflow_dispatch', 'github-hosted'] && ENV.fetch('GITHUB_REF').start_with?('refs/heads/')
    raise 'Output already exists' if File.exist?(output)
    raise 'Sources changed before archive packaging' unless identity(root) == expected_identity
    inspect_native(root, archive)
    FileUtils.mkdir_p(output)
    ConverterFfiIOSPackage.command('ditto', '-c', '-k', '--keepParent', archive, File.join(output, 'EpubToMp3.xcarchive.zip'))
    write_receipt(root, output, expected_identity, provenance: {
      'source_sha' => ENV.fetch('GITHUB_SHA'), 'repository' => ENV.fetch('GITHUB_REPOSITORY'),
      'run_id' => ENV.fetch('GITHUB_RUN_ID'), 'run_attempt' => ENV.fetch('GITHUB_RUN_ATTEMPT'),
      'workflow' => 'converter-ffi-ios-prebuilt.yml', 'mode' => 'build_app_only',
      'xcode' => ConverterFfiIOSPackage.command('xcodebuild', '-version')
    })
    verify(root, output)
  end
end

if $PROGRAM_NAME == __FILE__
  action, root, *arguments = ARGV
  abort 'Usage: package_ios_validation_archive.rb identity ROOT | package ROOT ARCHIVE OUTPUT IDENTITY | verify ROOT PACKAGE' unless root &&
    { 'identity' => 0, 'package' => 3, 'verify' => 1 }[action] == arguments.length
  result = IOSValidationArchive.public_send(action, File.expand_path(root), *arguments)
  puts(action == 'identity' ? result : 'iOS validation archive verified')
end
