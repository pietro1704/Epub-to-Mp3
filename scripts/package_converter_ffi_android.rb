#!/usr/bin/env ruby
# Validate and package real arm64 Piper/JNI ELF plus its complete phonemizer assets.
require 'digest'
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'fetch_onnxruntime_android'

root = File.expand_path('..', __dir__)
Dir.chdir(root)
audit_only = ARGV.include?('--audit')
unless audit_only
  lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
  abort 'Another heavy job is active' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
end
build_root = File.join(root, 'target', 'piper-android')
source = File.join(build_root, 'aarch64-linux-android', 'release', 'libconverter_ffi.so')
manifest_path = "#{source}.runtime.json"
abort 'Build the Piper/JNI Android artifact first: mise run converter-ffi:android-arm64' unless File.file?(manifest_path)
manifest = JSON.parse(File.read(manifest_path))
ort_directory = AndroidOnnxRuntime.validate(manifest.fetch('ort_directory'))
abort 'Android ONNX runtime differs from its recorded build' unless manifest['ort_sha256'] == AndroidOnnxRuntime::LIBRARY_SHA256
abort 'The artifact was not built with Piper/JNI features' unless manifest['target'] == 'aarch64-linux-android' && manifest['ort_api'] == 23 && %w[android-jni piper-runtime].all? { |feature| manifest.fetch('features').include?(feature) }
abort 'Android artifact differs from its recorded build' unless File.file?(source) && Digest::SHA256.file(source).hexdigest == manifest['sha256']
bytes = File.binread(source, 20)
abort 'Android library must be ELF64 little-endian AArch64' unless bytes[0, 4] == "\x7fELF" && bytes.getbyte(4) == 2 && bytes.getbyte(5) == 1 && bytes[18, 2].unpack1('v') == 183
host = RbConfig::CONFIG['host_os'].match?(/darwin/) ? 'darwin-x86_64' : 'linux-x86_64'
tools = File.join(manifest.fetch('ndk'), 'toolchains', 'llvm', 'prebuilt', host)
readelf = File.join(tools, 'bin', 'llvm-readelf')
nm = File.join(tools, 'bin', 'llvm-nm')
abort 'The recorded NDK inspection tools are unavailable' unless File.executable?(readelf) && File.executable?(nm)
symbols, status = Open3.capture2(nm, '--dynamic', '--defined-only', source)
abort 'Cannot inspect Android native exports' unless status.success?
imports, status = Open3.capture2(nm, '--dynamic', '--undefined-only', source)
abort 'Cannot inspect Android native imports' unless status.success?
abort 'Android converter imports the incompatible GNU C++ ABI' if imports.match?(/__cxx11|GLIBCXX/)
required_symbols = %w[piper_runtime_init piper_synthesize Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvertWithOptions Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePiperSynthesizeWithOptions Java_com_pietrocode_epubtomp3_flutter_1app_BackgroundChapterWorker_nativeConvertWithOptions Java_com_pietrocode_epubtomp3_flutter_1app_BackgroundChapterWorker_nativeCancelConversion Java_com_pietrocode_epubtomp3_flutter_1app_BackgroundChapterWorker_nativePrepareConversion]
required_symbols.each do |symbol|
  abort "Missing native Piper/JNI export: #{symbol}" unless symbols.match?(/\b#{Regexp.escape(symbol)}$/)
end
dynamic, status = Open3.capture2(readelf, '--dynamic', source)
abort 'Cannot inspect Android ELF dependencies' unless status.success?
needed = dynamic.scan(/\(NEEDED\).*?\[([^\]]+)\]/).flatten
abort 'Android converter must link the verified shared ONNX runtime' unless needed.include?('libonnxruntime.so')
abort 'Android JNI must use shared Bionic instead of embedding libc.a' unless needed.include?('libc.so')
system_libraries = %w[libc.so libm.so libdl.so liblog.so libandroid.so libz.so libjnigraphics.so]
dependencies = needed.reject { |name| system_libraries.include?(name) }.to_h do |name|
  candidates = Dir.glob(File.join(build_root, '**', name))
  candidates.unshift(File.join(ort_directory, name))
  candidates << File.join(tools, 'sysroot', 'usr', 'lib', 'aarch64-linux-android', name)
  path = candidates.find { |candidate| File.file?(candidate) }
  abort "Missing Android runtime dependency: #{name}" unless path
  [name, path]
end
asset_source = Dir.glob(File.join(root, 'target', 'espeak-data', '**', 'out', 'build', 'espeak-ng-data', 'phontab')).map { |path| File.dirname(path) }.find { |directory| %w[phontab phondata phonindex lang/roa/pt].all? { |name| File.file?(File.join(directory, name)) } }
abort 'Complete eSpeak NG assets are absent; run converter-ffi:android-arm64 first' unless asset_source
jni = File.join(root, 'flutter_app', 'android', 'app', 'src', 'main', 'jniLibs', 'arm64-v8a')
assets = File.join(root, 'flutter_app', 'android', 'app', 'src', 'main', 'assets', 'espeak-ng-data')
if audit_only
  abort 'Packaged JNI artifact is absent or stale' unless File.file?(File.join(jni, 'libconverter_ffi.so')) && Digest::SHA256.file(File.join(jni, 'libconverter_ffi.so')).hexdigest == manifest['sha256']
  Dir.glob(File.join(asset_source, '**', '*')).select { |path| File.file?(path) }.map { |path| path.delete_prefix(asset_source + '/') }.each { |name| abort "Packaged eSpeak asset is absent or stale: #{name}" unless File.file?(File.join(assets, name)) && Digest::SHA256.file(File.join(assets, name)).hexdigest == Digest::SHA256.file(File.join(asset_source, name)).hexdigest }
  dependencies.each { |name, path| abort "Packaged ELF dependency is missing or stale: #{name}" unless File.file?(File.join(jni, name)) && Digest::SHA256.file(File.join(jni, name)).hexdigest == Digest::SHA256.file(path).hexdigest }
else
  FileUtils.mkdir_p(jni)
  FileUtils.cp(source, File.join(jni, 'libconverter_ffi.so'))
  dependencies.each { |name, path| FileUtils.cp(path, File.join(jni, name)) }
  FileUtils.mkdir_p(File.dirname(assets))
  staging = "#{assets}.staging"
  FileUtils.rm_rf(staging)
  FileUtils.cp_r(asset_source, staging)
  FileUtils.rm_rf(assets)
  FileUtils.mv(staging, assets)
end
if (apk_index = ARGV.index('--apk'))
  abort '--apk requires --audit' unless audit_only
  apk = File.expand_path(ARGV.fetch(apk_index + 1))
  abort "APK is missing: #{apk}" unless File.file?(apk)
  jar = File.join(ENV.fetch('JAVA_HOME'), 'bin', 'jar')
  abort 'A JDK jar tool is required to inspect packaged APK contents' unless File.executable?(jar)
  entries, status = Open3.capture2(jar, 'tf', apk)
  abort 'Cannot inspect APK ZIP entries' unless status.success?
  entries = entries.lines.map(&:strip)
  asset_names = Dir.glob(File.join(asset_source, '**', '*')).select { |path| File.file?(path) }.map { |path| 'assets/espeak-ng-data/' + path.delete_prefix(asset_source + '/') }
  native_names = ['libconverter_ffi.so', *dependencies.keys].map { |name| "lib/arm64-v8a/#{name}" }
  missing = [*native_names, *asset_names] - entries
  abort "APK omits native TTS inputs: #{missing.join(', ')}" unless missing.empty?
  abort 'APK advertises an unsupported native ABI' if entries.any? { |entry| entry.start_with?('lib/') && !entry.start_with?('lib/arm64-v8a/') }
  inspected_assets = %w[phontab phondata phonindex lang/roa/pt]
  Dir.mktmpdir('android-apk-tts-') do |directory|
    selected = [*native_names, *inspected_assets.map { |name| "assets/espeak-ng-data/#{name}" }]
    _, status = Open3.capture2(jar, 'xf', apk, *selected, chdir: directory)
    abort 'Cannot extract APK runtime inputs for inspection' unless status.success?
    # Gradle strips ELF debug sections. Normalize both sides with the same NDK
    # tool so the audit still rejects stale or replaced runtime code.
    strip = File.join(tools, 'bin', 'llvm-strip')
    { 'libconverter_ffi.so' => source, **dependencies }.each_with_index do |(name, original), index|
      normalized = [original, File.join(directory, 'lib/arm64-v8a', name)].each_with_index.map do |path, side|
        output = File.join(directory, "normalized-#{index}-#{side}.so")
        _, status = Open3.capture2(strip, '--strip-unneeded', '-o', output, path)
        abort "Cannot normalize APK native dependency: #{name}" unless status.success?
        Digest::SHA256.file(output).hexdigest
      end
      abort "APK native dependency is stale: #{name}" unless normalized.uniq.length == 1
    end
    apk_library = File.join(directory, 'lib/arm64-v8a/libconverter_ffi.so')
    apk_symbols, status = Open3.capture2(nm, '--dynamic', '--defined-only', apk_library)
    abort 'Cannot inspect APK JNI exports' unless status.success?
    required_symbols.each { |symbol| abort "APK JNI library lacks #{symbol}" unless apk_symbols.match?(/\b#{Regexp.escape(symbol)}$/) }
    inspected_assets.each do |name|
      packed = File.join(directory, 'assets/espeak-ng-data', name)
      abort "APK phonemizer asset is stale: #{name}" unless Digest::SHA256.file(packed).hexdigest == Digest::SHA256.file(File.join(asset_source, name)).hexdigest
    end
  end
  puts "Verified APK contains the actual Piper/JNI exports, dependent libraries and complete eSpeak assets: #{apk}"
end
puts "#{audit_only ? 'Verified' : 'Packaged'} Android arm64 Piper/JNI and eSpeak NG assets; runtime synthesis still requires an installed model and a device test"
