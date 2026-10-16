#!/usr/bin/env ruby
# Install a checksum-pinned native runtime without compiling ONNX Runtime.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'rubygems/version'
require 'tmpdir'

module PrebuiltOnnxRuntime
  VERSION = '1.28.2'.freeze
  ARTIFACTS = {
    'x86_64' => {
      archive_size: 9_207_322,
      archive_sha256: 'cef42f2a4fca3b23dd16914ead36229adc7d5c119d563aaa12cc5d1e9177f93d',
      library_sha256: '2bf27180c09e6fd3f407c9ab25205ebf1ff95f2d53bfa35e35409b5849e0ac70'
    },
    'arm64' => {
      archive_size: 8_041_795,
      archive_sha256: 'd9e5c0c79929e201f5b8eb095e6809a91ce78be9866a1bca0dfab7e20b40ae40',
      library_sha256: 'b0613d0ae53199a83b05fa48e169211498e9d40d54beaa372068ebe5ec5b0929'
    }
  }.freeze
  ROOT = File.expand_path('..', __dir__).freeze

  def self.architecture
    requested = ENV['ONNXRUNTIME_MACOS_ARCH']
    unless requested.nil? || requested.empty?
      abort "Unsupported requested native architecture: #{requested}" unless %w[x86_64 arm64].include?(requested)
      return requested
    end
    host = RbConfig::CONFIG['host_cpu']
    return 'x86_64' if %w[x86_64 amd64].include?(host)
    return 'arm64' if %w[arm64 aarch64].include?(host)
    abort "Unsupported native architecture: #{host}"
  end

  def self.artifact
    ARTIFACTS.fetch(architecture)
  end

  def self.archive_name
    "onnxruntime-osx-#{architecture}-#{VERSION}.zip"
  end

  def self.source_url
    "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v#{VERSION}/#{archive_name}"
  end

  def self.destination
    File.join(ROOT, 'target', 'onnxruntime-macos-prebuilt', architecture)
  end

  def self.inspect_command(*arguments)
    output, status = Open3.capture2e(*arguments)
    raise "#{arguments.join(' ')} failed: #{output}" unless status.success?
    output
  end

  def self.inspect_library(library)
    raise 'The native runtime library is missing or is a symlink' unless File.file?(library) && !File.symlink?(library)
    raise 'Native runtime checksum mismatch' unless Digest::SHA256.file(library).hexdigest == artifact.fetch(:library_sha256)
    arch = inspect_command('xcrun', 'lipo', '-archs', library).strip
    raise "Wrong native runtime architecture: #{arch}" unless arch == architecture
    load_commands = inspect_command('xcrun', 'otool', '-l', library)
    minimum = load_commands[/\bminos\s+(\S+)/, 1] || load_commands[/\bversion\s+(\S+)/, 1]
    raise "Runtime exceeds macOS 12 compatibility: #{minimum}" unless minimum && Gem::Version.new(minimum) <= Gem::Version.new('12.0')
    dependencies = inspect_command('xcrun', 'otool', '-L', library).lines.drop(1).map { |line| line.strip.split.first }
    raise 'Unexpected native runtime install name' unless dependencies.shift == '@rpath/libonnxruntime.dylib'
    raise 'Native runtime contains an unbundled dependency' unless dependencies.all? { |path| path.start_with?('/System/Library/', '/usr/lib/') }
    exports = inspect_command('xcrun', 'nm', '-gU', library)
    raise 'Native runtime is missing its C API or CPU provider' unless exports.match?(/\b_OrtGetApiBase\s*$/) && exports.match?(/\b_OrtSessionOptionsAppendExecutionProvider_CPU\s*$/)
    minimum
  end

  def self.validate(directory = destination)
    manifest = JSON.parse(File.read(File.join(directory, 'runtime.json')))
    raise 'Unrecognized prebuilt runtime manifest' unless manifest['schema_version'] == 1 && manifest['version'] == VERSION && manifest['architecture'] == architecture && manifest['archive_sha256'] == artifact.fetch(:archive_sha256) && manifest['sha256'] == artifact.fetch(:library_sha256) && manifest['library'] == 'lib/libonnxruntime.dylib' && manifest['source_url'] == source_url
    library = File.join(directory, manifest.fetch('library'))
    minimum = inspect_library(library)
    raise 'Native runtime deployment metadata mismatch' unless manifest['minimum_macos'] == minimum
    files = manifest.fetch('files')
    raise 'Native runtime headers or licenses are missing' unless files.keys.any? { |path| path == 'include/onnxruntime_c_api.h' } && files.key?('LICENSE') && files.key?('ThirdPartyNotices.txt')
    files.each do |relative, digest|
      raise 'Invalid runtime manifest file path' if relative.start_with?('/') || relative.split('/').any? { |part| part == '..' }
      file = File.join(directory, relative)
      raise "Runtime package checksum mismatch: #{relative}" unless File.file?(file) && !File.symlink?(file) && Digest::SHA256.file(file).hexdigest == digest
    end
    File.dirname(library)
  end

  def self.verified_archive?(path)
    File.file?(path) && File.size(path) == artifact.fetch(:archive_size) && Digest::SHA256.file(path).hexdigest == artifact.fetch(:archive_sha256)
  end

  def self.install
    begin
      return validate
    rescue StandardError => error
      warn "Preparing verified prebuilt runtime: #{error.message}"
    end
    # Downloads/extraction are serialized with native builds. Validation above is
    # read-only and remains safe inside an existing product build lease.
    lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
    raise 'Another heavy job is active; retry runtime preparation after it finishes' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
    parent = File.dirname(destination)
    FileUtils.mkdir_p(parent)
    archive = File.join(parent, archive_name)
    unless verified_archive?(archive)
      supplied = ENV['ONNXRUNTIME_PREBUILT_ARCHIVE']
      supplied ||= File.join('/tmp/epub2mp3-ort-prebuilt-inspect', architecture == 'arm64' ? 'ort-arm64.zip' : 'ort.zip')
      if File.file?(supplied)
        raise 'Supplied native runtime archive failed checksum verification' unless verified_archive?(supplied)
        FileUtils.cp(supplied, archive)
      else
        partial = "#{archive}.part"
        success = system('curl', '--fail', '--location', '--silent', '--show-error', '--retry', '2', '--connect-timeout', '15', '--max-time', '120', '--max-filesize', artifact.fetch(:archive_size).to_s, '--continue-at', '-', '--output', partial, source_url, out: $stderr, err: $stderr)
        raise "Runtime download failed; partial download preserved: #{partial}" unless success
        raise "Runtime archive failed checksum verification; preserved for inspection: #{partial}" unless verified_archive?(partial)
        File.rename(partial, archive)
      end
    end
    stage = Dir.mktmpdir('.onnxruntime-install-', parent)
    begin
      prefix = "onnxruntime-osx-#{architecture}-#{VERSION}"
      entries = inspect_command('unzip', '-Z1', archive).lines.map(&:strip)
      raise 'Unsafe native runtime archive layout' unless entries.all? { |entry| entry.start_with?("#{prefix}/") && !entry.split('/').include?('..') }
      inspect_command('unzip', '-q', archive, "#{prefix}/lib/libonnxruntime.dylib", "#{prefix}/include/*", "#{prefix}/LICENSE", "#{prefix}/ThirdPartyNotices.txt", '-d', stage)
      extracted = File.join(stage, prefix)
      minimum = inspect_library(File.join(extracted, 'lib', 'libonnxruntime.dylib'))
      files = Dir.glob(File.join(extracted, '**', '*')).select { |path| File.file?(path) }.to_h do |path|
        raise 'Symlinks are not allowed in the normalized runtime package' if File.symlink?(path)
        [path.delete_prefix("#{extracted}/"), Digest::SHA256.file(path).hexdigest]
      end
      manifest = { 'schema_version' => 1, 'version' => VERSION, 'architecture' => architecture, 'minimum_macos' => minimum, 'execution_provider' => 'CPU', 'source_url' => source_url, 'archive_sha256' => artifact.fetch(:archive_sha256), 'sha256' => artifact.fetch(:library_sha256), 'library' => 'lib/libonnxruntime.dylib', 'files' => files }
      File.write(File.join(extracted, 'runtime.json'), JSON.pretty_generate(manifest))
      validate(extracted)
      if File.exist?(destination)
        # Preserve any incomplete package for inspection rather than deleting it.
        File.rename(destination, "#{destination}.previous-#{Process.pid}-#{Time.now.to_i}")
      end
      File.rename(extracted, destination)
      validate
    ensure
      FileUtils.remove_entry(stage) if File.exist?(stage)
    end
  ensure
    lease&.close
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts PrebuiltOnnxRuntime.install
  rescue StandardError => error
    abort error.message
  end
end
