# frozen_string_literal: true

# These exports are required in both the built ELF and the actual APK payload.
module AndroidJniExports
  REQUIRED = %w[
    piper_runtime_init
    piper_synthesize
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeConvertWithOptions
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePiperSynthesizeWithOptions
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeJobLog
    Java_com_pietrocode_epubtomp3_flutter_1app_BackgroundChapterWorker_nativeConvertWithOptions
    Java_com_pietrocode_epubtomp3_flutter_1app_BackgroundChapterWorker_nativeCancelConversion
    Java_com_pietrocode_epubtomp3_flutter_1app_BackgroundChapterWorker_nativePrepareConversion
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
end
