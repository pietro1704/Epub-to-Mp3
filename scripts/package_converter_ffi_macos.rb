#!/usr/bin/env ruby
# Create and verify the trusted Intel macOS converter-ffi build artifact.
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'

module ConverterFfiMacOSPackage
  SCHEMA_VERSION = 1
  RUST_TARGET = 'x86_64-apple-darwin'.freeze
  SOURCE_PATHS = %w[
    Cargo.toml Cargo.lock mise.toml rust-toolchain.toml rust-toolchain .cargo/config.toml
    crates/converter-core crates/converter-ffi native/piper-runtime
    native/vendor/piper-rs native/vendor/espeak-rs native/vendor/espeak-rs-sys
    scripts/build_onnxruntime_macos.sh scripts/prepare_onnxruntime_macos.rb
    scripts/fetch_onnxruntime_macos.rb scripts/native_job.rb scripts/bundle_espeak_ng_data.sh
    scripts/package_converter_ffi_macos.rb
    .github/workflows/converter-ffi-macos-intel-prebuilt.yml
  ].freeze
  ORT_VERSION = '1.28.2'.freeze
  ORT_SHA256 = '2bf27180c09e6fd3f407c9ab25205ebf1ff95f2d53bfa35e35409b5849e0ac70'.freeze

  module_function

  def canonical_json(value)
    JSON.generate(sort_hash(value))
  end

  def sort_hash(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, sort_hash(value.fetch(key))] }
    when Array then value.map { |item| sort_hash(item) }
    else value
    end
  end

  def source_digests(root)
    output, status = Open3.capture2('git', '-C', root, 'ls-files', '-z', '--', *SOURCE_PATHS)
    raise 'Cannot enumerate tracked build inputs' unless status.success?

    paths = output.split("\0")
    %w[scripts/package_converter_ffi_macos.rb .github/workflows/converter-ffi-macos-intel-prebuilt.yml].each do |required|
      raise "Required producer input is not tracked: #{required}" unless paths.include?(required)
    end
    paths.uniq.sort.to_h do |relative|
      path = File.join(root, relative)
      raise "Tracked build input is missing: #{relative}" unless File.file?(path) && !File.symlink?(path)
      [relative, Digest::SHA256.file(path).hexdigest]
    end
  end

  def identity(root)
    {
      'schema_version' => SCHEMA_VERSION,
      'platform' => 'macos',
      'architecture' => 'x86_64',
      'rust_target' => RUST_TARGET,
      'features' => ['piper-runtime'],
      'profile' => 'release',
      'deployment_target' => '12.0',
      'rustflags' => [],
      'cc' => 'Apple Clang selected by Xcode 16.4',
      'ort_prefer_dynamic' => true,
      'ort' => { 'version' => ORT_VERSION, 'library_sha256' => ORT_SHA256 },
      'source_files' => source_digests(root)
    }
  end

  def native_toolchain
    rustc = command('rustc', '-Vv')
    xcode = command('xcodebuild', '-version').lines.map(&:strip).reject(&:empty?).join(' ')
    sdk = command('xcrun', '--sdk', 'macosx', '--show-sdk-version').strip
    raise 'Expected Xcode 16.4' unless xcode.match?(/Xcode 16\.4(?:\s|$)/)
    raise 'Expected macOS SDK 15.5' unless sdk == '15.5'
    { 'rustc' => rustc.lines.map(&:strip).join(' '), 'xcode' => xcode, 'macos_sdk' => sdk }
  end

  def validate_build_environment!(require_ort: true)
    raise 'Unexpected Rust compiler flags in build environment' unless ENV.fetch('RUSTFLAGS', '').empty? && ENV.fetch('CARGO_ENCODED_RUSTFLAGS', '').empty?
    raise 'Unexpected C compiler override in build environment' unless ENV.fetch('CC', '').empty? && ENV.fetch('CXX', '').empty? && ENV.fetch('CFLAGS', '').empty? && ENV.fetch('CXXFLAGS', '').empty?
    raise 'Unexpected SDKROOT override in build environment' unless ENV.fetch('SDKROOT', '').empty?
    target = ENV.fetch('CARGO_BUILD_TARGET', '')
    raise "Unexpected Cargo target override: #{target}" unless target.empty? || target == RUST_TARGET
    raise 'Unexpected macOS deployment target' unless ENV.fetch('MACOSX_DEPLOYMENT_TARGET', '12.0') == '12.0'
    raise 'ORT_PREFER_DYNAMIC must be enabled for the prebuilt artifact' unless ENV.fetch('ORT_PREFER_DYNAMIC_LINK', '1') == '1'
    if require_ort
      ort = ENV.fetch('ORT_LIB_LOCATION', '')
      library = File.join(ort, 'libonnxruntime.dylib')
      raise 'Checksum-pinned Intel ONNX Runtime is not selected' unless File.file?(library) && Digest::SHA256.file(library).hexdigest == ORT_SHA256
    end
  end

  def command(*args)
    output, status = Open3.capture2e(*args)
    raise "#{args.join(' ')} failed: #{output}" unless status.success?
    output
  end

  def package(root, output, source_sha, run_id, run_attempt, toolchain: nil, inspect_native: true)
    raise 'Source SHA must be a full lowercase Git SHA' unless source_sha.match?(/\A[0-9a-f]{40}\z/)
    raise 'Actions run ID must be numeric' unless run_id.match?(/\A[0-9]+\z/)
    raise 'Actions run attempt must be numeric' unless run_attempt.match?(/\A[0-9]+\z/)
    validate_build_environment!(require_ort: inspect_native)
    toolchain ||= native_toolchain
    validate_toolchain!(toolchain)
    head, status = Open3.capture2('git', '-C', root, 'rev-parse', 'HEAD')
    raise 'Cannot determine checked out source commit' unless status.success? && head.strip == source_sha
    _diff, clean_status = Open3.capture2('git', '-C', root, 'diff', '--quiet', 'HEAD', '--', *SOURCE_PATHS)
    raise 'Build inputs differ from the checked out commit' unless clean_status.success?
    untracked, untracked_status = Open3.capture2('git', '-C', root, 'ls-files', '-o', '--exclude-standard', '-z', '--', *SOURCE_PATHS)
    raise 'Cannot inspect untracked build inputs' unless untracked_status.success?
    raise "Untracked build input found: #{untracked.split("\0").first}" unless untracked.empty?
    output = File.expand_path(output)
    raise 'Package output must not exist' if File.exist?(output) || File.symlink?(output)
    library = File.join(root, 'target', RUST_TARGET, 'release', 'libconverter_ffi.dylib')
    raise "Built FFI library is missing: #{library}" unless File.file?(library) && !File.symlink?(library)
    data_root = File.join(root, 'target', 'espeak-data')
    data = Dir.glob(File.join(data_root, '**', 'espeak-ng-data', 'phontab')).find do |path|
      File.file?(File.join(File.dirname(path), 'phondata'))
    end
    raise 'Complete eSpeak NG build data is missing' unless data
    data = File.dirname(data)
    id = identity(root)
    FileUtils.mkdir_p(File.dirname(output))
    Dir.mkdir(output)
    created_output = true
    FileUtils.cp(library, File.join(output, 'libconverter_ffi.dylib'))
    FileUtils.cp_r(data, File.join(output, 'espeak-ng-data'), preserve: true)
    packaged_library = File.join(output, 'libconverter_ffi.dylib')
    normalize_install_name(packaged_library) if inspect_native
    inspect_macho(packaged_library) if inspect_native
    files = file_digests(output)
    receipt = {
      'schema_version' => SCHEMA_VERSION,
      'identity' => id,
      'identity_sha256' => Digest::SHA256.hexdigest(canonical_json(id)),
      'toolchain' => toolchain,
      'source_sha' => source_sha,
      'producer' => { 'workflow' => 'converter-ffi-macos-intel-prebuilt', 'event' => 'workflow_dispatch', 'ref' => 'refs/heads/master', 'run_id' => run_id, 'run_attempt' => run_attempt },
      'files' => files
    }
    File.write(File.join(output, 'receipt.json'), JSON.pretty_generate(sort_hash(receipt)) + "\n")
    verify(root, output, inspect_native: inspect_native)
    output
  rescue StandardError
    FileUtils.remove_entry(output) if created_output && File.directory?(output)
    raise
  end

  def file_digests(package)
    files = []
    Find.find(package) do |path|
      next if path == package
      raise "Package contains a symlink: #{path}" if File.symlink?(path)
      relative = path.delete_prefix("#{package}/")
      if File.directory?(path)
        raise "Package contains an unexpected directory: #{relative}" unless relative == 'espeak-ng-data' || relative.start_with?('espeak-ng-data/')
      elsif File.file?(path)
        files << path
      else
        raise "Package contains a non-regular file: #{relative}"
      end
    end
    files.to_h { |path| [path.delete_prefix("#{package}/"), Digest::SHA256.file(path).hexdigest] }.sort.to_h
  end

  def verify(root, package, expected_identity_sha: nil, inspect_native: true)
    raise 'Package must be a plain directory' unless File.directory?(package) && !File.symlink?(package)
    package = File.expand_path(package)
    actual = file_digests(package)
    allowed = %w[libconverter_ffi.dylib receipt.json] + actual.keys.grep(%r{\Aespeak-ng-data/})
    raise 'Package has unexpected files' unless actual.keys.sort == allowed.sort
    raise 'eSpeak NG runtime data is incomplete' unless actual.keys.include?('espeak-ng-data/phontab') && actual.keys.include?('espeak-ng-data/phondata')
    receipt = JSON.parse(File.read(File.join(package, 'receipt.json')))
    raise 'Unsupported package receipt schema' unless receipt['schema_version'] == SCHEMA_VERSION
    id = identity(root)
    id_sha = Digest::SHA256.hexdigest(canonical_json(id))
    raise 'Package source/build recipe mismatch' unless receipt['identity'] == id && receipt['identity_sha256'] == id_sha
    raise 'Unexpected build identity' if expected_identity_sha && id_sha != expected_identity_sha
    validate_toolchain!(receipt['toolchain'])
    raise 'Package file hashes mismatch' unless receipt['files'] == actual.reject { |path, _| path == 'receipt.json' }
    raise 'Receipt source commit is invalid' unless receipt['source_sha'].to_s.match?(/\A[0-9a-f]{40}\z/)
    producer = receipt['producer']
    producer_valid = producer.is_a?(Hash) && producer['workflow'] == 'converter-ffi-macos-intel-prebuilt' && producer['event'] == 'workflow_dispatch' && producer['ref'] == 'refs/heads/master' && producer['run_id'].to_s.match?(/\A[0-9]+\z/) && producer['run_attempt'].to_s.match?(/\A[0-9]+\z/)
    raise 'Receipt producer metadata is invalid' unless producer_valid
    inspect_macho(File.join(package, 'libconverter_ffi.dylib')) if inspect_native
    package
  end

  def inspect_macho(library)
    raise 'FFI library is missing or is a symlink' unless File.file?(library) && !File.symlink?(library)
    architectures = command('xcrun', 'lipo', '-archs', library).strip
    raise "Wrong FFI architecture: #{architectures}" unless architectures == 'x86_64'
    load_commands = command('xcrun', 'otool', '-l', library)
    minimum = load_commands[/\bminos\s+(\S+)/, 1] || load_commands[/LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+(\S+)/m, 1]
    raise "FFI library exceeds macOS 12 deployment target: #{minimum.inspect}" unless minimum == '12.0'
    dependencies = command('xcrun', 'otool', '-L', library).lines.drop(1).map { |line| line.strip.split.first }
    raise 'FFI library has an unexpected dependency' unless dependencies.all? { |path| path.start_with?('/System/Library/', '/usr/lib/') || %w[@rpath/libconverter_ffi.dylib @rpath/libonnxruntime.dylib].include?(path) }
    raise 'FFI library is missing Piper/ORT linkage' unless dependencies.include?('@rpath/libonnxruntime.dylib')
    exports = command('xcrun', 'nm', '-gU', library)
    required = %w[_converter_session_open _converter_session_free _converter_bytes_free]
    missing = required.reject { |symbol| exports.match?(/\b#{Regexp.escape(symbol)}\s*$/) }
    raise "FFI library is missing C ABI exports: #{missing.join(', ')}" unless missing.empty?
  end

  def normalize_install_name(library)
    command('xcrun', 'install_name_tool', '-id', '@rpath/libconverter_ffi.dylib', library)
  end

  def validate_toolchain!(toolchain)
    valid = toolchain.is_a?(Hash) && toolchain['rustc'].is_a?(String) && !toolchain['rustc'].empty? &&
      toolchain['xcode'].is_a?(String) && toolchain['xcode'].match?(/\AXcode 16\.4(?:\s|$)/) &&
      toolchain['macos_sdk'] == '15.5'
    raise 'Producer toolchain is incompatible with this artifact contract' unless valid
  end

  def main(argv)
    action = argv.shift
    options = {}
    until argv.empty?
      key = argv.shift
      raise "Unexpected argument: #{key}" unless key.start_with?('--') && argv.any?
      options[key.delete_prefix('--')] = argv.shift
    end
    root = File.expand_path(options.fetch('root', File.expand_path('..', __dir__)))
    case action
    when 'identity'
      puts JSON.pretty_generate(sort_hash(identity(root)))
    when 'package'
      puts package(root, options.fetch('output'), options.fetch('source-sha'), options.fetch('run-id'), options.fetch('run-attempt'))
    when 'verify'
      puts verify(root, options.fetch('package'), expected_identity_sha: options['expected-identity-sha'])
    else
      raise 'Usage: package_converter_ffi_macos.rb identity|package|verify [--root ROOT] ...'
    end
    0
  rescue StandardError => error
    warn "error: #{error.message}"
    1
  end
end

exit ConverterFfiMacOSPackage.main(ARGV) if $PROGRAM_NAME == __FILE__
