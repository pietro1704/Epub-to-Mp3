import Combine
import Foundation

/// Whether the reader is showing the passage being narrated. The reader publishes it; the expanded player hides
/// "Go to reading" while both are paired. Anything unknown (no reader, other book, nothing narrated) is unpaired.
@MainActor
final class ReaderNarrationPairing: ObservableObject {
    @Published private(set) var isPaired = false
    /// The reader that last published; a stale reader being torn down must not clobber its successor.
    private var owner: ObjectIdentifier?

    func publish(paired: Bool, owner: ObjectIdentifier? = nil) {
        self.owner = owner
        if paired != isPaired { isPaired = paired }
    }

    /// Resets to unpaired when `owner` is still the publishing reader.
    func release(owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        publish(paired: false, owner: nil)
    }

    /// PDF: paired when the page holding the narrated character is one of the visible pages.
    nonisolated static func isPaired(spokenPage: Int?, visiblePages: [Int]) -> Bool {
        guard let spokenPage else { return false }
        return visiblePages.contains(spokenPage)
    }

    /// Paired when the reader shows the chapter being narrated and the spoken character is on the visible page.
    nonisolated static func isPaired(spokenChapter: Int?, spokenOffset: Int?,
                                     readerChapter: Int?, visible: NSRange?) -> Bool {
        guard let spokenChapter, let spokenOffset, let readerChapter, let visible,
              spokenChapter == readerChapter, visible.location != NSNotFound, visible.length > 0 else { return false }
        return NSLocationInRange(spokenOffset, visible)
    }
}
