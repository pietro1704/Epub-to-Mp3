# frozen_string_literal: true

# Host-only validation for converter-ffi target mapping and artifact names.

require_relative "build_converter_ffi"

module ValidateConverterFfiTargets
  EXPECTED = {
    "android-arm64" => ["aarch64-linux-android", "libconverter_ffi.so"],
    "android-armv7" => ["armv7-linux-androideabi", "libconverter_ffi.so"],
    "android-x64" => ["x86_64-linux-android", "libconverter_ffi.so"],
    "android-x86" => ["i686-linux-android", "libconverter_ffi.so"],
    "ios-device" => ["aarch64-apple-ios", "libconverter_ffi.dylib"],
    "ios-simulator-arm64" => ["aarch64-apple-ios-sim", "libconverter_ffi.dylib"],
    "ios-simulator-x64" => ["x86_64-apple-ios", "libconverter_ffi.dylib"]
  }.freeze
  JNI_ABIS = %w[arm64-v8a armeabi-v7a x86_64 x86].freeze

  module_function

  def check(condition, description)
    return if condition

    warn "AssertionError: #{description}"
    exit 1
  end

  def main(root = File.expand_path("..", __dir__))
    builder = BuildConverterFfi
    check(builder::TARGETS == EXPECTED.transform_values(&:first), "TARGETS mapping differs from the expected mapping")
    EXPECTED.each do |name, (target, library)|
      check(builder.artifact_path(root, name) == File.join(root, "target", target, "release", library), "artifact path for #{name}")
      next unless name.start_with?("android-")

      jni = builder.android_jni_path(root, name)
      check(File.basename(jni) == "libconverter_ffi.so", "JNI library name for #{name}")
      check(JNI_ABIS.include?(File.basename(File.dirname(jni))), "JNI ABI directory for #{name}")
    end
    puts "validated #{EXPECTED.length} converter-ffi target mappings"
    0
  end
end

exit ValidateConverterFfiTargets.main if $PROGRAM_NAME == __FILE__
