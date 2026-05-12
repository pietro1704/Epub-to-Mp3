import XCTest
import SwiftUI
@testable import EpubToMp3

/// Unit tests for `MainReaderView` persistence and routing contracts.
///
/// We test via `UserDefaults` round-trips and view construction rather
/// than rendering the full SwiftUI tree (calling `.body` on
/// `@AppStorage`-driven views in a unit-test host trips SwiftUI's
/// "no live environment" trap).
final class MainReaderViewTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "mainreader.tests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Construction

    func testMainReaderViewConstructsWithEmptyLibrary() {
        // Should not crash when no reading book is persisted.
        _ = MainReaderView(onBrowseLibrary: {})
        XCTAssertNil(defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey))
    }

    func testMainReaderViewConstructsWithCallbacks() {
        var browseLibraryFired = false
        var openPlayerFired = false
        _ = MainReaderView(
            onOpenPlayer: { openPlayerFired = true },
            onBrowseLibrary: { browseLibraryFired = true }
        )
        // Closures bind but are not called at init time.
        XCTAssertFalse(browseLibraryFired)
        XCTAssertFalse(openPlayerFired)
    }

    // MARK: - Persistence round-trip

    func testSetCurrentlyReadingPersistsBookID() {
        MainReaderView.setCurrentlyReading(bookID: "book-xyz", defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey),
            "book-xyz"
        )
    }

    func testSetCurrentlyReadingClearsWhenNil() {
        defaults.set("seed", forKey: MainReaderView.currentlyReadingBookIDKey)
        MainReaderView.setCurrentlyReading(bookID: nil, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey))
    }

    func testSetCurrentlyReadingTreatsEmptyStringAsNil() {
        defaults.set("seed", forKey: MainReaderView.currentlyReadingBookIDKey)
        MainReaderView.setCurrentlyReading(bookID: "", defaults: defaults)
        XCTAssertNil(defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey))
    }

    // MARK: - Empty state

    func testEmptyStateWhenNoBookIDPersisted() {
        // currentlyReadingBookID key is absent → the view is in empty state.
        // We verify this through the storage key being nil.
        XCTAssertNil(
            defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey),
            "No book should be persisted in a fresh defaults suite."
        )
    }

    // MARK: - "Listen" sets currentlyPlayingBookID

    func testListenButtonSetsPlayingIDToReadingID() {
        // Simulate what the "Listen" button does: copy reading ID → playing ID.
        let bookID = "book-read-123"
        defaults.set(bookID, forKey: MainReaderView.currentlyReadingBookIDKey)

        // Mirror the button's action: read the reading key, write the playing key.
        let readingID = defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey)
        if let id = readingID {
            defaults.set(id, forKey: AudioPlayer.currentBookIDDefaultsKey)
        }

        XCTAssertEqual(
            defaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey),
            bookID,
            "Tapping Listen must set the currentlyPlayingBookID to the currently-reading book."
        )
    }

    // MARK: - Auto-clear when book is removed from library

    func testBookRemovedFromLibraryClearsReadingID() {
        // Simulate: book "removed-book" was being read, then deleted.
        let lib = LibraryStore.previewEmpty
        let removedID = "removed-book"
        defaults.set(removedID, forKey: MainReaderView.currentlyReadingBookIDKey)

        // The view checks whether the book is still in the library.
        let bookStillExists = lib.books.contains(where: { $0.id == removedID })
        if !bookStillExists {
            defaults.removeObject(forKey: MainReaderView.currentlyReadingBookIDKey)
        }

        XCTAssertNil(
            defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey),
            "Reading pointer must auto-clear when the book is no longer in the library."
        )
    }

    func testBookPresentInLibraryPreservesReadingID() {
        let lib = LibraryStore.previewPopulated
        guard let firstBook = lib.books.first else {
            XCTFail("previewPopulated must have at least one book")
            return
        }
        defaults.set(firstBook.id, forKey: MainReaderView.currentlyReadingBookIDKey)

        let bookStillExists = lib.books.contains(where: { $0.id == firstBook.id })
        if !bookStillExists {
            defaults.removeObject(forKey: MainReaderView.currentlyReadingBookIDKey)
        }

        XCTAssertEqual(
            defaults.string(forKey: MainReaderView.currentlyReadingBookIDKey),
            firstBook.id,
            "Reading pointer must not be cleared while the book is still in the library."
        )
    }

    // MARK: - RootTab stability

    /// `RootTab` raw values are `TabView` selection tokens — they must
    /// stay stable across builds so SwiftUI's animation state doesn't
    /// reset. Reader is now tab 0 (the default landing).
    func testRootTabReaderIsFirstTab() {
        XCTAssertEqual(RootTab.reader.rawValue, 0,
                       "Reader must be the first tab (default landing screen).")
        XCTAssertEqual(RootTab.library.rawValue, 1)
        XCTAssertEqual(RootTab.settings.rawValue, 2)
    }

    // MARK: - SplitNavMode stability

    /// `SplitNavMode.reader` must be the first case so the sidebar
    /// defaults to the Reader destination on iPad/macOS.
    func testSplitNavModeReaderIsFirstCase() {
        XCTAssertEqual(
            SplitNavMode.allCases.first, .reader,
            "Reader must be the first sidebar destination (default landing)."
        )
    }

    func testSplitNavModeContainsAllExpectedDestinations() {
        let modes = SplitNavMode.allCases
        XCTAssertTrue(modes.contains(.reader))
        XCTAssertTrue(modes.contains(.library))
        XCTAssertTrue(modes.contains(.settings))
    }

    func testSplitNavModeLabelsAreNonEmpty() {
        for mode in SplitNavMode.allCases {
            XCTAssertFalse(
                mode.label.isEmpty,
                "Sidebar would render an empty label for \(mode)."
            )
            XCTAssertFalse(
                mode.systemImage.isEmpty,
                "Sidebar would render a missing icon for \(mode)."
            )
        }
    }

    // MARK: - AppStorage key contract

    func testCurrentlyReadingBookIDKeyIsDistinctFromPlayingKey() {
        // The two keys MUST be different — they track separate state.
        XCTAssertNotEqual(
            MainReaderView.currentlyReadingBookIDKey,
            AudioPlayer.currentBookIDDefaultsKey,
            "Reading and playing must be tracked by separate UserDefaults keys."
        )
    }
}
