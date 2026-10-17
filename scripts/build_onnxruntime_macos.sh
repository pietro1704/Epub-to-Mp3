#!/usr/bin/env bash
set -euo pipefail

# Native CPU runtime preserving the product's macOS 12 deployment target.
# CMake's upstream code-generation tools may use Python; no Python runtime or
# bindings are included in the resulting library. No legacy build.sh is invoked.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
exec mise exec -- ruby "$project_root/scripts/native_job.rb" build -- mise exec -- ruby - "$project_root" <<'RUBY'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'

root = ARGV.fetch(0)
Dir.chdir(root)
abort 'This runtime builder requires macOS' unless RUBY_PLATFORM.include?('darwin')
source = ENV.fetch('ONNXRUNTIME_SOURCE_DIR', File.join(root, 'target', 'onnxruntime-ios15-src'))
host_cpu = RbConfig::CONFIG.fetch('host_cpu')
architecture = ENV.fetch('ONNXRUNTIME_MACOS_ARCH', %w[arm64 aarch64].include?(host_cpu) ? 'arm64' : 'x86_64')
abort 'Supported macOS runtime architectures are x86_64 and arm64' unless %w[x86_64 arm64].include?(architecture)
build_jobs = ENV.fetch('ONNXRUNTIME_BUILD_JOBS', '1')
abort 'ONNXRUNTIME_BUILD_JOBS must be 1 or 2' unless %w[1 2].include?(build_jobs)
developer = ENV.fetch('DEVELOPER_DIR', '/Applications/Xcode-16.4.0.app/Contents/Developer')
base_environment = {
  'DEVELOPER_DIR' => developer, 'MACOSX_DEPLOYMENT_TARGET' => '12.0',
  'SDKROOT' => nil, 'CC' => nil, 'CXX' => nil, 'CFLAGS' => nil, 'CXXFLAGS' => nil,
  'CMAKE_TOOLCHAIN_FILE' => nil, 'CMAKE_GENERATOR' => nil,
  'CMAKE_MAKE_PROGRAM' => nil, 'IPHONEOS_DEPLOYMENT_TARGET' => nil
}
def captured(environment, *command)
  output, status = Open3.capture2e(environment, *command)
  abort "#{command.join(' ')} failed: #{output}" unless status.success?
  output.strip
end
destination = File.join(root, 'target', architecture == 'x86_64' ? 'onnxruntime-macos12' : "onnxruntime-macos12-#{architecture}")
build = File.join(destination, "cmake-#{architecture}")
library_directory = File.join(destination, 'build')
target = File.join(library_directory, 'libonnxruntime.1.24.2.dylib')
manifest_path = File.join(destination, 'runtime.json')
if File.file?(target) && File.file?(manifest_path)
  begin
    manifest = JSON.parse(File.read(manifest_path))
    architecture_valid = captured(base_environment, 'xcrun', 'lipo', '-archs', target) == architecture
    load_commands = captured(base_environment, 'xcrun', 'otool', '-l', target)
    minimum = load_commands[/\bminos\s+(\S+)/, 1] || load_commands[/LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+(\S+)/m, 1]
    link = File.join(library_directory, 'libonnxruntime.dylib')
    link_valid = File.symlink?(link) && File.exist?(link) && File.realpath(link) == File.realpath(target)
    if link_valid && architecture_valid && minimum == '12.0' && manifest['version'] == '1.24.2' && manifest['architecture'] == architecture && manifest['minimum_macos'] == minimum && manifest['execution_provider'] == 'CPU' && manifest['sha256'] == Digest::SHA256.file(target).hexdigest
      warn "Reusing verified #{architecture} ONNX Runtime with macOS 12 deployment metadata"
      puts library_directory
      exit 0
    end
  rescue JSON::ParserError
    warn 'Runtime manifest is incomplete; resuming the native build'
  end
end
unless File.exist?(source)
  FileUtils.mkdir_p(File.dirname(source))
  warn 'Fetching official ONNX Runtime v1.24.2 sources for a fresh native build'
  abort 'Could not fetch ONNX Runtime; existing partial sources have been preserved' unless system('git', 'clone', '--depth', '1', '--branch', 'v1.24.2', 'https://github.com/microsoft/onnxruntime.git', source, out: $stderr, err: $stderr)
end
abort 'ONNX Runtime source is incomplete or is not version 1.24.2; existing partial sources have been preserved' unless File.file?(File.join(source, 'VERSION_NUMBER')) && File.read(File.join(source, 'VERSION_NUMBER')).strip == '1.24.2'
required_dependencies = %w[abseil_cpp date eigen3 flatbuffers gsl mp11 nlohmann_json onnx protobuf protoc_binary pytorch_cpuinfo re2 safeint]
source_pools = [File.join(source, 'build', 'iOS', 'Release', '_deps'), File.join(build, '_deps')]
cached_sources = {}
source_pools.each do |pool|
  Dir.glob(File.join(pool, '*-src')).sort.each do |directory|
    next if Dir.children(directory).empty?
    cached_sources[File.basename(directory).delete_suffix('-src')] ||= directory
  end
end
fully_cached = required_dependencies.all? { |name| cached_sources.key?(name) }
warn 'Missing native dependency sources will be fetched by standard CMake FetchContent' unless fully_cached
sdk = captured(base_environment, 'xcrun', '--sdk', 'macosx', '--show-sdk-path')
clang = captured(base_environment, 'xcrun', '--sdk', 'macosx', '--find', 'clang')
clang_cpp = captured(base_environment, 'xcrun', '--sdk', 'macosx', '--find', 'clang++')
FileUtils.mkdir_p(build)
log = File.join(build, 'build.log')
flags = [
  '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0',
  "-DCMAKE_OSX_ARCHITECTURES=#{architecture}", "-DCMAKE_OSX_SYSROOT=#{sdk}",
  "-DCMAKE_C_COMPILER=#{clang}", "-DCMAKE_CXX_COMPILER=#{clang_cpp}",
  '-DCMAKE_COMPILE_WARNING_AS_ERROR=OFF', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
  "-DFETCHCONTENT_FULLY_DISCONNECTED=#{fully_cached ? 'ON' : 'OFF'}", '-DFETCHCONTENT_UPDATES_DISCONNECTED=ON',
  '-Donnxruntime_BUILD_SHARED_LIB=ON', '-Donnxruntime_BUILD_UNIT_TESTS=OFF',
  '-Donnxruntime_BUILD_BENCHMARKS=OFF', '-Donnxruntime_ENABLE_PYTHON=OFF',
  '-Donnxruntime_BUILD_CSHARP=OFF', '-Donnxruntime_BUILD_JAVA=OFF',
  '-Donnxruntime_ENABLE_TRAINING=OFF', '-Donnxruntime_ENABLE_TRAINING_APIS=OFF',
  '-Donnxruntime_ENABLE_TRAINING_OPS=OFF', '-Donnxruntime_USE_COREML=OFF',
  '-Donnxruntime_USE_CUDA=OFF', '-Donnxruntime_USE_TENSORRT=OFF',
  '-Donnxruntime_USE_DNNL=OFF', '-Donnxruntime_USE_OPENVINO=OFF',
  '-Donnxruntime_USE_XNNPACK=OFF', '-Donnxruntime_USE_WEBGPU=OFF',
  '-Donnxruntime_USE_QNN=OFF', '-Donnxruntime_USE_NNAPI_BUILTIN=OFF',
  '-Donnxruntime_USE_MIMALLOC=OFF', '-Donnxruntime_USE_TELEMETRY=OFF',
  '-Donnxruntime_ENABLE_LTO=OFF', '-Donnxruntime_MINIMAL_BUILD=OFF',
  '-Donnxruntime_USE_FULL_PROTOBUF=ON', '-Dprotobuf_BUILD_SHARED_LIBS=OFF',
  '-DONNX_BUILD_PYTHON=OFF', '-DONNX_GEN_PB_TYPE_STUBS=OFF'
]
cached_sources.each do |name, directory|
  flags << "-DFETCHCONTENT_SOURCE_DIR_#{name.upcase}=#{directory}"
end
protoc = cached_sources['protoc_binary'] && File.join(cached_sources['protoc_binary'], 'bin', 'protoc')
flags << "-DONNX_CUSTOM_PROTOC_EXECUTABLE=#{protoc}" if protoc && File.executable?(protoc)
File.open(log, 'a') do |output|
  commands = [
    ['mise', 'exec', '--', 'cmake', '--compile-no-warning-as-error', '-S', File.join(source, 'cmake'), '-B', build, '-G', 'Ninja', *flags],
    ['mise', 'exec', '--', 'cmake', '--build', build, '--target', 'onnxruntime', '--parallel', build_jobs]
  ]
  commands.each do |command|
    warn "ONNX Runtime macOS 12 #{architecture}: #{command.include?('--build') ? 'building CPU runtime' : 'configuring cached sources'}; log #{log}"
    output.puts(command.join(' ')); output.flush
    abort "Native runtime build failed; inspect #{log}" unless system(base_environment, *command, out: output, err: output)
  end
end
produced = File.join(build, 'libonnxruntime.1.24.2.dylib')
abort "CMake did not produce #{produced}" unless File.file?(produced)
architectures = captured(base_environment, 'xcrun', 'lipo', '-archs', produced)
abort "Incorrect runtime architecture: #{architectures}" unless architectures == architecture
load_commands = captured(base_environment, 'xcrun', 'otool', '-l', produced)
minimum = load_commands[/\bminos\s+(\S+)/, 1] || load_commands[/LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+(\S+)/m, 1]
abort "Runtime deployment target changed: #{minimum.inspect}" unless minimum == '12.0'
linked = captured(base_environment, 'xcrun', 'otool', '-L', produced)
linked.lines.drop(2).each do |line|
  dependency = line.strip.split(' ').first
  abort "Unpackaged non-system runtime dependency: #{dependency}" unless dependency.start_with?('/usr/lib/', '/System/Library/')
end
exports = captured(base_environment, 'xcrun', 'nm', '-gU', produced)
abort 'Runtime does not export OrtGetApiBase' unless exports.include?('_OrtGetApiBase')
FileUtils.mkdir_p(library_directory)
target = File.join(library_directory, File.basename(produced))
FileUtils.cp(produced, target)
FileUtils.ln_sf(File.basename(target), File.join(library_directory, 'libonnxruntime.dylib'))
FileUtils.mkdir_p(File.join(destination, 'include'))
Dir.glob(File.join(source, 'include', 'onnxruntime', 'core', 'session', '*.h')).each { |header| FileUtils.cp(header, File.join(destination, 'include')) }
File.write(File.join(destination, 'runtime.json'), JSON.pretty_generate({ 'version' => '1.24.2', 'architecture' => architecture, 'minimum_macos' => minimum, 'source' => source, 'sha256' => Digest::SHA256.file(target).hexdigest, 'execution_provider' => 'CPU' }))
warn "Verified CPU library architecture and macOS 12 deployment metadata; actual synthesis verification is still required"
puts library_directory
RUBY
