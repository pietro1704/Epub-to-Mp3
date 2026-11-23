#if os(iOS)
import Foundation

@MainActor
enum ReaderListeningStartLocation {
    /// Capture the source page before asynchronous file access or playback
    /// teardown can publish another chapter. A PDF owns a separate exact anchor.
    static func pageRatio(bookID: String, chapter: Int, explicitRatio: Double?,
                          voiceChange: ReaderVoiceChange?, pdfAnchor: PDFReadingAudioMap.Anchor?,
                          location: ReaderLocation) -> Double? {
        if let voiceChange { return voiceChange.pageRatio }
        guard pdfAnchor == nil else { return nil }
        if let explicitRatio { return explicitRatio }
        guard location.readingBookID == bookID,
              location.readerChapter == chapter,
              let ratio = location.pageRatio,
              ratio.isFinite, ratio > 0, ratio <= 1 else { return nil }
        return ratio
    }
}
#endif
