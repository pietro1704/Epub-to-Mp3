#if os(iOS)
import Foundation

@MainActor
enum ReaderListeningStartLocation {
    /// Capture the source page before asynchronous file access or playback
    /// teardown can publish another chapter. A PDF owns a separate exact anchor.
    static func pageRatio(bookID: String, chapter: Int, explicitRatio: Double?,
                          voiceChange: ReaderVoiceChange?, pdfAnchor: PDFReadingAudioMap.Anchor?,
                          defaults: UserDefaults) -> Double? {
        if let voiceChange { return voiceChange.pageRatio }
        guard pdfAnchor == nil else { return nil }
        if let explicitRatio { return explicitRatio }
        guard defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) == bookID,
              defaults.object(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey) as? Int == chapter,
              let ratio = defaults.object(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey) as? Double,
              ratio.isFinite, ratio > 0, ratio <= 1 else { return nil }
        return ratio
    }
}
#endif
