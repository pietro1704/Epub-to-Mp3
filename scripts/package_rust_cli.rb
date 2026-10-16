#!/usr/bin/env ruby
# Package the native Rust CLI with its runtime dependencies and phonemizer data.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'rubygems/version'

root = File.expand_path('..', __dir__)
Dir.chdir(root)
mode = ARGV.shift
abort 'Usage: package_rust_cli.rb --package-only | --run -- [CLI arguments]' unless %w[--package-only --run].include?(mode)
ARGV.shift if ARGV.first == '--'
macos = RbConfig::CONFIG['host_os'].include?('darwin')
windows = RbConfig::CONFIG['host_os'].match?(/mswin|mingw/)
# Preparing a missing runtime acquires its own lease. Do it before taking the CLI lease.
runtime = nil
if macos
  runtime = IO.popen(['mise', 'exec', '--', 'ruby', 'scripts/prepare_onnxruntime_macos.rb'], &:read).strip
  abort 'Could not prepare the macOS 12 native ONNX Runtime' unless $?.success? && File.directory?(runtime)
end
lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
abort 'Another heavy job is active' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
build_environment = {}
if macos
  build_environment = { 'ORT_LIB_LOCATION' => runtime, 'ORT_PREFER_DYNAMIC_LINK' => '1', 'MACOSX_DEPLOYMENT_TARGET' => '12.0', 'SDKROOT' => nil, 'CMAKE_TOOLCHAIN_FILE' => nil, 'CMAKE_GENERATOR' => nil, 'CC' => nil, 'CXX' => nil, 'CFLAGS' => nil, 'CXXFLAGS' => nil }
end
abort 'Rust CLI build failed' unless system(build_environment, 'mise', 'exec', '--', 'rustup', 'run', 'stable', 'cargo', 'build', '-p', 'converter-cli', '--bin', 'converter-cli', '--release', '--jobs', '1', out: $stderr, err: $stderr)
name = windows ? 'converter-cli.exe' : 'converter-cli'
compiled = File.join(root, 'target', 'release', name)
abort "Missing compiled native CLI: #{compiled}" unless File.file?(compiled)
asset_candidates = %w[target/release target/espeak-data/debug].flat_map do |directory|
  Dir.glob(File.join(root, directory, 'build', 'espeak-rs-sys-*', 'out', '{share,build}', 'espeak-ng-data', 'phontab'))
end
assets = asset_candidates.map { |path| File.dirname(path) }.find { |directory| %w[phontab phondata phonindex pt_dict].all? { |entry| File.file?(File.join(directory, entry)) } }
abort 'The native CLI build did not produce complete Piper/eSpeak runtime assets' unless assets
parent = File.join(root, 'dist')
package = File.join(parent, 'epub-to-mp3-cli')
abort 'Refusing to replace an unrelated directory without a CLI package manifest' if File.exist?(package) && !File.file?(File.join(package, 'package.json'))
FileUtils.mkdir_p(parent)
def inspected(*command)
  text, status = Open3.capture2e(*command)
  abort "#{command.join(' ')} failed: #{text}" unless status.success?
  text
end
stage = Dir.mktmpdir('.epub-to-mp3-cli-', parent)
begin
  bin = File.join(stage, 'bin')
  FileUtils.mkdir_p(bin)
  executable = File.join(bin, name)
  FileUtils.cp(compiled, executable)
  FileUtils.cp_r(assets, File.join(bin, 'espeak-ng-data'))
  if macos
    runtime_library = Dir.glob(File.join(runtime, 'libonnxruntime*.dylib')).find { |path| !File.symlink?(path) }
    abort 'The prepared native runtime is missing its dylib' unless runtime_library
    minimum = inspected('xcrun', 'otool', '-l', runtime_library)[/\bminos\s+(\S+)/, 1]
    abort "The native runtime would raise compatibility above macOS 12: #{minimum}" unless minimum && Gem::Version.new(minimum) <= Gem::Version.new('12.0')
    FileUtils.cp(runtime_library, File.join(bin, File.basename(runtime_library)))
    dependency = inspected('xcrun', 'otool', '-L', executable).lines.drop(1).map { |line| line.strip.split(' ').first }.find { |path| path.include?('libonnxruntime') }
    abort 'The native CLI does not link the packaged ONNX Runtime' unless dependency
    abort 'The native CLI and ONNX Runtime have different architectures' unless inspected('xcrun', 'lipo', '-archs', executable).strip == inspected('xcrun', 'lipo', '-archs', runtime_library).strip
    abort 'Could not make the CLI runtime relocatable' unless system('xcrun', 'install_name_tool', '-change', dependency, "@executable_path/#{File.basename(runtime_library)}", executable, out: $stderr, err: $stderr)
    cli_minimum = inspected('xcrun', 'otool', '-l', executable)[/\bminos\s+(\S+)/, 1]
    abort "The CLI exceeds its macOS 12 target: #{cli_minimum}" unless cli_minimum && Gem::Version.new(cli_minimum) <= Gem::Version.new('12.0')
    [File.join(bin, File.basename(runtime_library)), executable].each do |artifact|
      abort 'Could not sign the relocatable native CLI artifact' unless system('codesign', '--force', '--sign', '-', artifact, out: $stderr, err: $stderr)
      abort 'The packaged native CLI signature is invalid' unless system('codesign', '--verify', '--strict', artifact, out: $stderr, err: $stderr)
    end
  elsif windows
    Dir.glob(File.join(root, 'target', 'release', '*.dll')).each { |library| FileUtils.cp(library, bin) }
  else
    # Static ONNX Runtime is the normal non-Apple build. Keep any explicitly built shared dependency adjacent.
    Dir.glob(File.join(root, 'target', 'release', '*.so*')).each { |library| FileUtils.cp(library, bin) }
  end
  files = Dir.glob(File.join(stage, '**', '*')).select { |path| File.file?(path) }.to_h { |path| [path.delete_prefix("#{stage}/"), Digest::SHA256.file(path).hexdigest] }
  File.write(File.join(stage, 'package.json'), JSON.pretty_generate({ 'runtime' => 'native Rust/Piper', 'host' => RbConfig::CONFIG['host'], 'model_weights_included' => false, 'files' => files }))
  backup = "#{package}.previous"
  abort 'A previous CLI package backup needs reconciliation' if File.exist?(backup)
  File.rename(package, backup) if File.exist?(package)
  begin
    File.rename(stage, package)
    FileUtils.rm_rf(backup) if File.exist?(backup)
  rescue Exception
    File.rename(backup, package) if File.exist?(backup) && !File.exist?(package)
    raise
  end
ensure
  FileUtils.rm_rf(stage) if File.exist?(stage)
end
executable = File.join(package, 'bin', name)
if mode == '--run'
  # The packaged dylib resolves relative to the executable; a development loader path is unnecessary.
  exit(system({ 'DYLD_LIBRARY_PATH' => nil, 'ORT_LIB_LOCATION' => nil }, executable, *ARGV) ? 0 : ($?.exitstatus || 1))
end
puts executable
