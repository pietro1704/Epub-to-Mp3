import Foundation

/// UI-level decision unit that combines `AudioPlayer.shouldUseSpeechFallback`
/// (MP3-availability check) with `EbookFulltext` chapter text lookup to
/// drive a single banner / button state in the reader.
///
/// - `hidden`: don't surface anything. MP3 is ready OR no chapter text
///   is on hand. Either way, nothing useful to offer.
/// - `available(text:languageCode:)`: MP3 is missing but the chapter
///   text is on hand — UI should expose a "Read aloud" / "Listen with
///   accessibility voice" affordance.
/// - `active`: the fallback synthesizer is already playing — UI should
///   show pause/stop controls and hide the offer banner.
enum SpeechFallbackOffer: Equatable {
    case hidden
    case available(text: String, languageCode: String?)
    case active
}

/// Pure decision helper. Side-effect free so the reader's `body` can
/// recompute it cheaply on every state change. Mirrors
/// `AudioPlayer.shouldUseSpeechFallback(for:chapterIndex:)` but layers
/// in `EbookFulltext` text-availability checks since only the reader
/// owns the text payload.
enum SpeechFallbackUI {

    static func offer(
        isFallbackActive: Bool,
        snapshot: JobSnapshot?,
        chapterIndex: Int,
        fulltext: EbookFulltext?,
        languageCode: String?
    ) -> SpeechFallbackOffer {
        if isFallbackActive { return .active }

        if !mp3IsMissing(snapshot: snapshot, chapterIndex: chapterIndex) {
            return .hidden
        }

        guard let text = chapterText(in: fulltext, chapterIndex: chapterIndex),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .hidden }

        return .available(text: text, languageCode: languageCode)
    }

    /// Mirror of `AudioPlayer.shouldUseSpeechFallback(for:chapterIndex:)`
    /// without the AudioPlayer dependency, so this helper can be unit
    /// tested without standing up an AVQueuePlayer.
    private static func mp3IsMissing(snapshot: JobSnapshot?, chapterIndex: Int) -> Bool {
        guard let snapshot else { return true }
        let playable = snapshot.playableChapters
        if playable.isEmpty { return true }
        return !playable.contains { $0.index == chapterIndex }
    }

    /// Resolve chapter text from `EbookFulltext`. The backend numbers
    /// fulltext chapters starting at **1** (`server.py::get_job_fulltext`),
    /// while `JobSnapshot.Chapter.index` is **0**-based. We match the
    /// same fallback strategy as `PlayerReaderView.chapter(in:at:)`:
    /// try 1-based mapping first, then fall back to positional indexing.
    private static func chapterText(in fulltext: EbookFulltext?, chapterIndex: Int) -> String? {
        guard let fulltext else { return nil }
        let oneBased = chapterIndex + 1
        if let direct = fulltext.chapters.first(where: { $0.index == oneBased }) {
            return direct.text
        }
        if chapterIndex >= 0, chapterIndex < fulltext.chapters.count {
            return fulltext.chapters[chapterIndex].text
        }
        return nil
    }
}
