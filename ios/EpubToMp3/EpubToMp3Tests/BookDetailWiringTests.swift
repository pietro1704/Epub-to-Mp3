import XCTest
@testable import EpubToMp3

@MainActor
final class BookDetailWiringTests: XCTestCase {
    func testCanonicalListeningPriorityUsesOnlyTheActiveBookLiveAnchor() throws {
        let suite = "listening-priority-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("active-book", forKey: ReaderSessionState.currentlyReadingBookIDKey)
        defaults.set(8, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        XCTAssertEqual(ReaderPlaybackPriorityChapter.index(bookID: "active-book", defaults: defaults), 8)
        XCTAssertEqual(ReaderPlaybackPriorityChapter.index(bookID: "different-book", defaults: defaults), 0)
        defaults.set(-1, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        XCTAssertEqual(ReaderPlaybackPriorityChapter.index(bookID: "active-book", defaults: defaults), 0)
    }
}
