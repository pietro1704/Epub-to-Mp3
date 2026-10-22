import Foundation

/// C callback shims borrow exactly the contexts retained for one conversion call.
enum ConverterCallbackBridge {
    static let platformTtsCallback: PlatformTtsCallback = {
        text, language, output, cancelled, cancelContext, errorBuffer, errorLength, context in
        guard let text, let language, let output, let context else { return false }
        let provider = Unmanaged<PlatformSpeechSynthesizer>.fromOpaque(context).takeUnretainedValue()
        do {
            try provider.synthesizeWAV(text: String(cString: text), language: String(cString: language),
                                      output: URL(fileURLWithPath: String(cString: output)),
                                      cancelled: { cancelled?(cancelContext) ?? false })
            return true
        } catch {
            if let errorBuffer, errorLength > 0 {
                let bytes = Array(error.localizedDescription.utf8.prefix(Int(errorLength) - 1))
                for (index, byte) in bytes.enumerated() { errorBuffer[index] = CChar(bitPattern: byte) }
                errorBuffer[bytes.count] = 0
            }
            return false
        }
    }

    static let progressCallback: ConverterChapterCallback = { eventJSON, context in
        guard let eventJSON, let context else { return }
        let box = Unmanaged<ConversionCallbackReceipt>
            .fromOpaque(context)
            .takeUnretainedValue()
        box.progress(Data(String(cString: eventJSON).utf8))
    }

    static let chapterCallback: ConverterChapterCallback = { eventJSON, context in
        guard let eventJSON, let context else { return }
        let box = Unmanaged<ConversionCallbackReceipt>
            .fromOpaque(context)
            .takeUnretainedValue()
        box.chapterHandler?(box.voiceReceipt.chapter(Data(String(cString: eventJSON).utf8)))
    }

    static let audioChunkCallback: ConverterAudioChunkCallback = {
        chapterIndex, chunkIndex, bytes, byteCount, context in
        guard let bytes, byteCount > 0, let context else { return false }
        let box = Unmanaged<ConversionCallbackReceipt>.fromOpaque(context).takeUnretainedValue()
        return box.audioChunkHandler?(chapterIndex, chunkIndex, Data(bytes: bytes, count: byteCount)) ?? false
    }

}
