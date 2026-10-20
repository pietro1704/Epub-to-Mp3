# frozen_string_literal: true
require_relative '../../../scripts/native_job'
NativeJob.build_entrypoint(__FILE__, ARGV)
require 'fileutils'
root = File.expand_path('../../..', __dir__)
downloads = File.join(root, '.reports/tts-six/20261014/downloads')
build = File.join(downloads, 'sentencepiece-ios-build')
def checked(*args)
  abort "Failed #{args.first}" unless system(*args)
end
  developer = '/Applications/Xcode-16.4.0.app/Contents/Developer'
  include_path = File.join(downloads, 'sentencepiece-ios-properties.cmake')
  File.write(include_path, "function(set_xcode_property target property value)\nif(TARGET ${target})\nset_property(TARGET ${target} PROPERTY XCODE_ATTRIBUTE_${property} ${value})\nendif()\nendfunction()\n")
  checked('env', "DEVELOPER_DIR=#{developer}", 'cmake', '-S', File.join(downloads, 'sentencepiece-0.2.1'), '-B', build, "-DCMAKE_PROJECT_INCLUDE=#{include_path}", '-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_SYSROOT=iphoneos', '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0', '-DCMAKE_BUILD_TYPE=Release', '-DSPM_ENABLE_SHARED=OFF', '-DSPM_ENABLE_TCMALLOC=OFF', '-DSPM_ENABLE_NFKC_COMPILE=OFF', '-DSPM_BUILD_TEST=OFF', '-DSPM_ENABLE_TRAINER=OFF')
  checked('env', "DEVELOPER_DIR=#{developer}", 'cmake', '--build', build, '--target', 'sentencepiece-static', '--parallel', '1')
  headers = File.join(downloads, 'frameworks/onnxruntime.xcframework/ios-arm64/onnxruntime.framework/Headers')
  checked('env', "DEVELOPER_DIR=#{developer}", 'xcrun', '--sdk', 'iphoneos', 'clang++', '-target', 'arm64-apple-ios15.0', '-std=c++17', '-O2', '-DPTT_SHARED_LIB=1', '-I', headers, '-I', File.join(downloads, 'sentencepiece-0.2.1/src'), '-I', downloads, '-c', File.join(downloads, 'pocket_tts.cpp'), '-o', File.join(downloads, 'pocket.o'))
