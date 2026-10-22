import XCTest
@testable import EpubToMp3
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class BookDetailWiringTests: XCTestCase {
    func testBookDetailReadActionForwardsExactBookIdentityWithoutStartingConversion() throws {
        let suite = "book-detail-actions-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let book = BookEntity(id: suite, title: "Action fixture", bookmark: Data(), displayFilename: "fixture.epub", addedAt: .distantPast)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
#if os(macOS)
        var opened: [String] = []
        let controller = MacBookDetailViewController(book: book, library: LibraryStore(defaults: defaults),
            settings: AppSettings(defaults: defaults), player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            onRead: { opened.append($0) }, onShowJobs: {}, conversionExecutor: { _, _, _, _, _, _, _ in
                XCTFail("Read must not synthesize audio")
                throw CancellationError()
            })
        let content = try XCTUnwrap(controller.view as? MacBookDetailContent)
        XCTAssertNotNil(content.listenButton.action)
        XCTAssertNotNil(content.downloadButton.action)
        content.readButton.performClick(nil)
        XCTAssertEqual(opened, [book.id])
        XCTAssertNil(player.snapshot)
#else
        throw XCTSkip("AppKit action adapter; UIKit book actions run in NativeResponsiveScreenTests.")
#endif
    }

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
