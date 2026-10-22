import Foundation

final class ConversionCallbackReceipt: @unchecked Sendable {
    private let fallbackNotice = PlatformFallbackNoticeTracker()
    let voiceReceipt: PlatformSpeechVoiceReceipt
    let progressHandler: (@Sendable (Data) -> Void)?
    let chapterHandler: (@Sendable (Data) -> Void)?
    let audioChunkHandler: (@Sendable (Int, Int, Data) -> Bool)?

    func progress(_ raw: Data) {
        let data = voiceReceipt.progress(raw)
        if fallbackNotice.shouldNotify(progress: data) {
            let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let engine = fields?["fallbackUsed"] as? Bool == true ? fields?["engine"] as? String : nil
            Task { @MainActor in PlatformFallbackNotice.show(engine: engine) }
        }
        progressHandler?(data)
    }

    init(
        voiceReceipt: PlatformSpeechVoiceReceipt,
        progressHandler: (@Sendable (Data) -> Void)?,
        chapterHandler: (@Sendable (Data) -> Void)?,
        audioChunkHandler: (@Sendable (Int, Int, Data) -> Bool)? = nil
    ) {
        self.voiceReceipt = voiceReceipt
        self.progressHandler = progressHandler
        self.chapterHandler = chapterHandler
        self.audioChunkHandler = audioChunkHandler
    }
}
