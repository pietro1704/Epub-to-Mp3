#!/usr/bin/env ruby
# Build the shared Piper/JNI artifact under the existing native-work lease.
require 'digest'
require 'json'
require 'rbconfig'
require 'fileutils'

root = File.expand_path('..', __dir__)
Dir.chdir(root)
lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
abort 'Another heavy job is active' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
host = case RbConfig::CONFIG['host_os']
       when /darwin/ then 'darwin-x86_64'
       when /linux/ then 'linux-x86_64'
       else abort 'Unsupported Android NDK build host'
       end
ndk = ENV.fetch('ANDROID_NDK_HOME', File.expand_path('~/.local/share/mise/installs/android-sdk/11.0/ndk/28.2.13676358'))
toolchain = File.join(ndk, 'toolchains', 'llvm', 'prebuilt', host)
clang = File.join(toolchain, 'bin', 'aarch64-linux-android24-clang')
abort "Install the Android NDK first: #{clang}" unless File.executable?(clang)
target = 'aarch64-linux-android'
build_root = File.join(root, 'target', 'piper-android')
# mise may put a standalone rustc before rustup's proxies. Match cargo and rustc
# explicitly so cross-target standard libraries come from the same toolchain.
sysroot = IO.popen(['mise', 'exec', '--', 'rustup', 'run', 'stable', 'rustc', '--print', 'sysroot'], &:read).strip
abort 'Could not resolve the stable Rust compiler' unless $?.success? && File.executable?(File.join(sysroot, 'bin', 'rustc'))
# Host tools create architecture-independent phonemizer data; never run target ELF tools on the Mac.
data_env = %w[SDKROOT CC CXX AR CFLAGS CXXFLAGS CMAKE_TOOLCHAIN_FILE CMAKE_GENERATOR CMAKE_MAKE_PROGRAM ORT_LIB_LOCATION ORT_IOS_LINK BINDGEN_EXTRA_CLANG_ARGS CARGO_ENCODED_RUSTFLAGS].to_h { |key| [key, nil] }
data_env['RUSTC'] = File.join(sysroot, 'bin', 'rustc')
exit($?.exitstatus || 1) unless system(data_env, 'mise', 'exec', '--', 'rustup', 'run', 'stable', 'cargo', 'build', '-p', 'espeak-rs-sys', '--features', 'compile-espeak-intonations', '--target-dir', 'target/espeak-data', '--jobs', '1')
environment = data_env.merge(
  'ANDROID_NDK_HOME' => ndk, 'ANDROID_NDK_ROOT' => ndk,
  'PATH' => "#{File.join(toolchain, 'bin')}:#{ENV.fetch('PATH')}",
  'CC_aarch64_linux_android' => clang,
  'CXX_aarch64_linux_android' => File.join(toolchain, 'bin', 'aarch64-linux-android24-clang++'),
  'AR_aarch64_linux_android' => File.join(toolchain, 'bin', 'llvm-ar'),
  'CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER' => clang,
  'BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android' => "--target=arm64-linux-android24 --sysroot=#{File.join(toolchain, 'sysroot')} -include stdio.h",
  'CFLAGS_aarch64_linux_android' => "--sysroot=#{File.join(toolchain, 'sysroot')}",
  'CMAKE_TOOLCHAIN_FILE_aarch64_linux_android' => File.join(ndk, 'build', 'cmake', 'android.toolchain.cmake'),
  'CMAKE_GENERATOR' => 'Ninja',
  'CC' => nil, 'TARGET_CC' => nil,
  'HOST_CC' => host == 'darwin-x86_64' ? '/usr/bin/clang' : 'cc',
  'HOST_CXX' => host == 'darwin-x86_64' ? '/usr/bin/clang++' : 'c++',
  'RUSTUP_TOOLCHAIN' => 'stable',
  'ORT_LIB_LOCATION' => ENV['ANDROID_ORT_LIB_LOCATION'],
  'ORT_PREFER_DYNAMIC_LINK' => '0'
)
command = ['mise', 'exec', '--', 'rustup', 'run', 'stable', 'cargo', 'build', '-p', 'converter-ffi', '--features', 'android-jni,piper-runtime', '--release', '--target', target, '--target-dir', build_root, '--jobs', '1']
exit($?.exitstatus || 1) unless system(environment, *command)
library = File.join(build_root, target, 'release', 'libconverter_ffi.so')
abort 'Cargo did not produce the Android converter library' unless File.file?(library)
File.write("#{library}.runtime.json", JSON.pretty_generate({ 'target' => target, 'features' => ['android-jni', 'piper-runtime'], 'ort_api' => 23, 'sha256' => Digest::SHA256.file(library).hexdigest, 'ndk' => ndk }))
puts "Built Piper/JNI Android artifact: #{library}"
