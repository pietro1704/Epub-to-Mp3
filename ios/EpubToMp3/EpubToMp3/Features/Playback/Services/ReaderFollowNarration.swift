import Foundation

/// READER-FOLLOW-NARRATION: while a book is narrated, the reader turns the page by itself when the spoken
/// passage leaves the screen (forward or backward). A manual page turn suspends the following; it resumes when the
/// visible page holds the spoken passage again, on "Go to reading", or after an explicit narration jump
/// (seek, skip, chapter change, play-from-here). Pure: platform clients only translate their events into it.
struct ReaderFollowNarration: Equatable {
    enum Event: Equatable {
        /// The reader moved because of a user gesture or command (not because the reader followed).
        case manualPageTurn
        /// The user moved the narration itself: seek, skip, chapter change, play-from-here.
        case explicitNarrationJump
        /// The user asked the reader to go to the narrated passage.
        case goToReading
    }

    enum Direction: Equatable { case forward, backward }

    private(set) var isSuspended = false
    /// The narrated page the reader was last showing.
    private var shownPage: Int?

    mutating func apply(_ event: Event) {
        switch event {
        case .manualPageTurn: isSuspended = true
        case .explicitNarrationJump, .goToReading:
            isSuspended = false
            shownPage = nil
        }
    }

    /// Whether the reader must move to the spoken passage now. `paired` is the pairing state the reader
    /// publishes; `isNarrating` is true while the narration of this reader's book is playing.
    mutating func shouldFollow(paired: Bool, isNarrating: Bool, spokenPage: Int? = nil) -> Bool {
        if paired {
            isSuspended = false
            shownPage = spokenPage
            return false
        }
        // The narration is still on the page that was on screen, so it is the reader that moved.
        if let spokenPage, spokenPage == shownPage { isSuspended = true }
        return isNarrating && !isSuspended
    }

    /// EPUB/TXT: which way the reader must move to reach the spoken character, nil when it is on the page
    /// or unknown.
    nonisolated static func direction(spokenChapter: Int?, spokenOffset: Int?,
                                      readerChapter: Int?, visible: NSRange?) -> Direction? {
        guard let spokenChapter, let spokenOffset, let readerChapter, let visible,
              visible.location != NSNotFound, visible.length > 0 else { return nil }
        if spokenChapter != readerChapter { return spokenChapter > readerChapter ? .forward : .backward }
        if spokenOffset >= NSMaxRange(visible) { return .forward }
        return spokenOffset < visible.location ? .backward : nil
    }

    /// PDF: which way the reader must move to reach the spoken page, nil when it is visible or unknown.
    nonisolated static func direction(spokenPage: Int?, visiblePages: [Int]) -> Direction? {
        guard let spokenPage, let first = visiblePages.min(), let last = visiblePages.max(),
              !visiblePages.contains(spokenPage) else { return nil }
        return spokenPage > last ? .forward : (spokenPage < first ? .backward : nil)
    }
}
