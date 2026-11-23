# frozen_string_literal: true

# These exports are required in both the built ELF and the actual APK payload.
module AndroidJniExports
  REQUIRED = %w[
    piper_runtime_init
    piper_synthesize
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvertWithOptions
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePiperSynthesizeWithOptions
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeJobLog
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsCatalogV3
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeLibraryMetadata
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationCreate
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationPlan
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationEvent
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationRecordProgress
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationAccept
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationPublish
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationFail
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationCancel
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeTtsModelInstallOperationFree
  ].freeze

  def self.verify!(output, label: 'Android JNI library')
    exports = output.lines.filter_map do |line|
      # llvm-nm --dynamic --defined-only emits address, type and exact symbol.
      match = line.match(/\A\s*[0-9a-fA-F]+\s+[A-Za-z]\s+(\S+)\s*\z/)
      match[1] if match
    end
    missing = REQUIRED - exports
    raise "#{label} lacks required exports: #{missing.join(', ')}" unless missing.empty?

    true
  end

  def self.verify_apk_abis!(entries)
    unexpected = entries.filter_map do |entry|
      match = entry.match(%r{\Alib/([^/]+)/})
      match[1] if match && match[1] != 'arm64-v8a'
    end.uniq.sort
    raise "APK advertises an unsupported native ABI: #{unexpected.join(', ')}" unless unexpected.empty?

    true
  end
end
