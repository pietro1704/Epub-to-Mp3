#!/usr/bin/env ruby
# Install the pinned Android runtime without compiling ONNX or using Pyke archives.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'native_job'

module AndroidOnnxRuntime
  VERSION = '1.23.2'.freeze
  ARCHIVE_SIZE = 30_241_654
  ARCHIVE_SHA256 = '82048d1f462218adae4ba76477089ab0ba76093d84f733540066db1a8ba6b827'.freeze
  LIBRARY_SHA256 = 'e40f09d07dc53726b8bfbf48a7907673b8f86718a057655a62790a39874a7302'.freeze
  URL = "https://repo.maven.apache.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/#{VERSION}/onnxruntime-android-#{VERSION}.aar".freeze
  ROOT = File.expand_path('..', __dir__).freeze
  DESTINATION = File.join(ROOT, 'target', 'onnxruntime-android-prebuilt', 'arm64-v8a').freeze

  def self.command(*arguments)
    output, status = Open3.capture2e(*arguments)
    raise "#{arguments.join(' ')} failed: #{output}" unless status.success?
    output
  end

  def self.tools
    ndk = ENV['ANDROID_NDK_HOME'] || ENV['ANDROID_NDK_ROOT'] || File.expand_path('~/.local/share/mise/installs/android-sdk/11.0/ndk/28.2.13676358')
    host = RbConfig::CONFIG['host_os'].include?('darwin') ? 'darwin-x86_64' : 'linux-x86_64'
    directory = File.join(ndk, 'toolchains', 'llvm', 'prebuilt', host, 'bin')
    %w[llvm-readelf llvm-nm].each do |name|
      raise "Android NDK inspection tool is missing: #{directory}/#{name}" unless File.executable?(File.join(directory, name))
    end
    directory
  end

  def self.validate_library(path)
    raise 'The pinned Android ONNX library is missing or is a symlink' unless File.file?(path) && !File.symlink?(path)
    raise 'Android ONNX library checksum mismatch' unless Digest::SHA256.file(path).hexdigest == LIBRARY_SHA256
    header = File.binread(path, 20)
    raise 'Expected ELF64 little-endian AArch64 ONNX runtime' unless header[0, 4] == "\x7fELF" && header.getbyte(4) == 2 && header.getbyte(5) == 1 && header[16, 2].unpack1('v') == 3 && header[18, 2].unpack1('v') == 183
    directory = tools
    symbols = command(File.join(directory, 'llvm-nm'), '--dynamic', '--defined-only', path)
    raise 'Android ONNX runtime does not export OrtGetApiBase' unless symbols.match?(/\bOrtGetApiBase(?:@@?\S+)?$/)
    imports = command(File.join(directory, 'llvm-nm'), '--dynamic', '--undefined-only', path)
    raise 'Android ONNX runtime imports the incompatible GNU C++ ABI' if imports.match?(/__cxx11|GLIBCXX/)
    dynamic = command(File.join(directory, 'llvm-readelf'), '--dynamic', path)
    needed = dynamic.scan(/\(NEEDED\).*?\[([^\]]+)\]/).flatten
    raise "Android ONNX runtime has unsupported dependencies: #{needed.join(', ')}" unless !needed.empty? && (needed - %w[libdl.so liblog.so libm.so libc.so]).empty?
    path
  end

  def self.validate(directory = DESTINATION)
    manifest = JSON.parse(File.read(File.join(directory, 'runtime.json')))
    expected = { 'schema_version' => 1, 'version' => VERSION, 'abi' => 'arm64-v8a', 'ort_api' => 23, 'source_url' => URL, 'archive_sha256' => ARCHIVE_SHA256, 'sha256' => LIBRARY_SHA256 }
    raise 'Unrecognized Android ONNX runtime manifest' unless expected.all? { |key, value| manifest[key] == value }
    validate_library(File.join(directory, 'libonnxruntime.so'))
    directory
  end

  def self.ensure_runtime(already_locked: false)
    begin
      return validate
    rescue StandardError => error
      warn "Preparing the pinned Android ONNX runtime: #{error.message}"
    end
    # Compatibility argument never substitutes for a real inherited descriptor.
    lease, inherited = NativeJob.lease(NativeJob::LOCK_PATH)
    parent = File.dirname(DESTINATION)
    FileUtils.mkdir_p(parent)
    stage = Dir.mktmpdir('.onnxruntime-install-', parent)
    begin
      archive = ENV['ANDROID_ORT_ARCHIVE']
      if archive
        raise 'Supplied Android ONNX archive is missing' unless File.file?(archive)
      else
        archive = File.join(stage, 'runtime.aar')
        success = system('curl', '--fail', '--location', '--silent', '--show-error', '--retry', '2', '--connect-timeout', '15', '--max-time', '120', '--max-filesize', ARCHIVE_SIZE.to_s, '--output', archive, URL, out: $stderr, err: $stderr)
        raise 'Android ONNX runtime download failed' unless success
      end
      raise 'Android ONNX archive failed checksum verification' unless File.size(archive) == ARCHIVE_SIZE && Digest::SHA256.file(archive).hexdigest == ARCHIVE_SHA256
      # Extract one pinned archive member; never unpack unrelated AAR contents.
      command('unzip', '-q', archive, 'jni/arm64-v8a/libonnxruntime.so', '-d', stage)
      library = File.join(stage, 'jni', 'arm64-v8a', 'libonnxruntime.so')
      validate_library(library)
      package = File.join(stage, 'package')
      FileUtils.mkdir_p(package)
      FileUtils.cp(library, File.join(package, 'libonnxruntime.so'))
      manifest = { 'schema_version' => 1, 'version' => VERSION, 'abi' => 'arm64-v8a', 'ort_api' => 23, 'source_url' => URL, 'archive_sha256' => ARCHIVE_SHA256, 'sha256' => LIBRARY_SHA256 }
      File.write(File.join(package, 'runtime.json'), JSON.pretty_generate(manifest))
      validate(package)
      if File.exist?(DESTINATION)
        File.rename(DESTINATION, "#{DESTINATION}.previous-#{Process.pid}-#{Time.now.to_i}")
      end
      File.rename(package, DESTINATION)
      validate
    ensure
      # Only the private download/extraction tree is temporary. Installed product
      # libraries and caller-supplied archives are retained.
      FileUtils.remove_entry(stage) if File.exist?(stage)
    end
  ensure
    lease&.close unless inherited
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    abort 'Usage: fetch_onnxruntime_android.rb [--already-locked | --validate]' unless (ARGV - %w[--already-locked --validate]).empty?
    puts(ARGV.include?('--validate') ? AndroidOnnxRuntime.validate : AndroidOnnxRuntime.ensure_runtime(already_locked: ARGV.include?('--already-locked')))
  rescue StandardError => error
    abort error.message
  end
end
