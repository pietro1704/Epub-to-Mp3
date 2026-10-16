# frozen_string_literal: true
require_relative '../../../scripts/native_job'
NativeJob.build_entrypoint(__FILE__, ARGV)
require 'json'
require 'fileutils'
require 'digest'
require 'time'
root = File.expand_path('../../..', __dir__)
out = File.join(root, '.reports/tts-six/20261014')
downloads = File.join(out, 'downloads')
work = File.join(downloads, 'harness')
device = '44B2CFBD-2193-5086-8E8D-BF7A2876C321'
bundle = 'com.pietrocode.epubtomp3.uitests'
FileUtils.mkdir_p(work)
FileUtils.cp(File.join(__dir__, 'BenchmarkApp.swift'), work)
FileUtils.cp(File.join(downloads, 'SherpaOnnx.swift'), work)
FileUtils.cp(File.join(root, 'ios/EpubToMp3/EpubToMp3/Features/Conversion/Services/EdgeTTSBridge.swift'), work)
FileUtils.cp(File.join(root, 'ios/EpubToMp3/EpubToMp3/Shared/Concurrency/AsyncTimeout.swift'), work)
pocket_ready = File.file?(File.join(downloads, 'pocket.o'))
FileUtils.cp(File.join(__dir__, 'PocketBridge.h'), work) if pocket_ready
edge_library = File.join(downloads, 'edge-build/aarch64-apple-ios/release/libtts_phone_edge_probe.a')
edge_ready = File.file?(edge_library)
File.write(File.join(work, 'Bridge.h'), '#include <SherpaOnnxC/sherpa-onnx/c-api/c-api.h>' + "\n" + (pocket_ready ? '#include "PocketBridge.h"' + "\n" : '') + (edge_ready ? 'int benchmark_edge(const char *, const char *, char *, int);' + "\n" : ''))
conditions = []
linker = ['$(inherited)']
if pocket_ready
  conditions << 'POCKET_RUNTIME'
  linker += [File.join(downloads, 'pocket.o'), File.join(downloads, 'sentencepiece-ios-build/src/libsentencepiece.a'), '-lc++']
end
if edge_ready
  conditions << 'RUST_EDGE'
  linker += [edge_library, '-framework', 'Security', '-framework', 'SystemConfiguration']
end
pocket_settings = "SWIFT_ACTIVE_COMPILATION_CONDITIONS: '#{conditions.join(' ')}'\n    OTHER_LDFLAGS: #{linker.to_json}"
frameworks = File.join(downloads, 'frameworks')
File.write(File.join(work, 'project.yml'), <<~YAML)
  name: TTSBenchmark
  options:
    deploymentTarget:
      iOS: '15.0'
  settings:
    base:
      DEVELOPMENT_TEAM: HHRZ35A37Y
      CODE_SIGN_STYLE: Automatic
      SWIFT_VERSION: '5.0'
      SWIFT_OBJC_BRIDGING_HEADER: Bridge.h
      SWIFT_OPTIMIZATION_LEVEL: '-O'
      GENERATE_INFOPLIST_FILE: YES
      INFOPLIST_KEY_UIFileSharingEnabled: YES
      INFOPLIST_KEY_UILaunchScreen_Generation: YES
      PRODUCT_BUNDLE_IDENTIFIER: #{bundle}
      TARGETED_DEVICE_FAMILY: '1'
      #{pocket_settings}
  targets:
    TTSBenchmark:
      type: application
      platform: iOS
      sources:
        - BenchmarkApp.swift
        - SherpaOnnx.swift
        - EdgeTTSBridge.swift
        - AsyncTimeout.swift
      dependencies:
        - framework: #{frameworks}/sherpa-onnx.xcframework
          embed: true
        - framework: #{frameworks}/onnxruntime.xcframework
          embed: true
  schemes:
    TTSBenchmark:
      build:
        targets:
          TTSBenchmark: all
YAML
def checked(*args, log: nil)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  options = log ? { out: log, err: [:child, :out] } : {}
  abort "Failed: #{args.first}; log=#{log}" unless system(*args, **options)
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end
host = { started_utc: Time.now.utc.iso8601, phases: [] }
host_report = File.join(out, "host-phases-#{Time.now.utc.strftime('%H%M%S')}.json")
begin
  Dir.chdir(work) { checked('mise', 'exec', '--', 'xcodegen', 'generate') }
  build_seconds = checked('env', 'DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer', 'xcrun', 'xcodebuild', '-project', File.join(work, 'TTSBenchmark.xcodeproj'), '-scheme', 'TTSBenchmark', '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-derivedDataPath', File.join(work, 'build'), '-jobs', '1', '-allowProvisioningUpdates', 'build', log: File.join(out, 'build.log'))
  host[:phases] << { phase: 'app_build', seconds: build_seconds }
  app = File.join(work, 'build/Build/Products/Release-iphoneos/TTSBenchmark.app')
  checked('codesign', '--verify', '--strict', app)
  checked('xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, app)
  models = {
    'edresson' => 'vits-piper-pt_BR-edresson-low',
    'faber' => 'vits-piper-pt_BR-faber-medium',
    'kokoro' => 'kokoro-int8-multi-lang-v1_0',
    'supertonic' => 'sherpa-onnx-supertonic-3-tts-int8-2026-05-11'
  }
  models['pocket'] = 'pocket-portuguese' if pocket_ready
  inventory = models.map do |engine, name|
    dir = File.join(downloads, name)
    files = Dir.glob(File.join(dir, '**/*')).select { |f| File.file?(f) }.map { |f| { path: f.delete_prefix(dir + '/'), bytes: File.size(f), sha256: Digest::SHA256.file(f).hexdigest } }
    { engine: engine, package: name, installed_bytes: files.sum { |f| f[:bytes] }, files: files }
  end
  File.write(File.join(out, 'model-inventory.json'), JSON.pretty_generate(inventory) + "\n")
  models.each do |engine, name|
    seconds = checked('xcrun', 'devicectl', 'device', 'copy', 'to', '--device', device, '--source', File.join(downloads, name), '--destination', "Documents/models/#{name}", '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--timeout', '180', log: File.join(out, "transfer-#{engine}.log"))
    host[:phases] << { phase: 'transfer', engine: engine, seconds: seconds }
  end
  ENV.fetch('TTS_ENGINES', 'edresson,faber,kokoro,supertonic,edge,pocket').split(',').each do |engine|
    puts "Benchmarking #{engine} on iPhone 16e"
    STDOUT.flush
    seconds = checked('xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device, '--terminate-existing', '--console', '--timeout', '240', bundle, '--', '-engine', engine, log: File.join(out, "launch-#{engine}.log"))
    host[:phases] << { phase: 'native_benchmark_wall', engine: engine, seconds: seconds }
    previous = File.join(out, engine)
    FileUtils.mv(previous, previous + '-previous-' + Time.now.utc.strftime('%H%M%S')) if File.directory?(previous)
    seconds = checked('xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device, '--source', "Documents/results/#{engine}", '--destination', File.join(out, engine), '--domain-type', 'appDataContainer', '--domain-identifier', bundle, log: File.join(out, "collect-#{engine}.log"))
    host[:phases] << { phase: 'collection', engine: engine, seconds: seconds }
    File.write(host_report, JSON.pretty_generate(host) + "\n")
  end
ensure
  # This unique test bundle owns all copied model files. Production data is untouched.
  system('xcrun', 'devicectl', 'device', 'uninstall', 'app', '--device', device, bundle, out: File.join(out, 'uninstall.log'), err: [:child, :out])
  host[:finished_utc] = Time.now.utc.iso8601
  File.write(host_report, JSON.pretty_generate(host) + "\n")
end
