import XCTest
@testable import EpubToMp3

#if os(iOS)
import UIKit
#endif

final class RootViewMiniPlayerTests: XCTestCase {
    func testMiniPlayerShowsWhenPlayableBookExistsOutsideReader() {
        let visible = RootView.shouldShowMiniPlayer(
            currentBookID: "book-1",
            currentlyReadingBookID: nil,
            availableBookIDs: ["book-1", "book-2"]
        )

        XCTAssertTrue(visible)
    }

    func testMiniPlayerHidesWhenReaderOwnsCurrentBook() {
        let visible = RootView.shouldShowMiniPlayer(
            currentBookID: "book-1",
            currentlyReadingBookID: "book-1",
            availableBookIDs: ["book-1", "book-2"]
        )

        XCTAssertFalse(visible)
    }

    func testMiniPlayerHidesWhenCurrentBookIsMissingFromLibrary() {
        let visible = RootView.shouldShowMiniPlayer(
            currentBookID: "book-1",
            currentlyReadingBookID: nil,
            availableBookIDs: ["book-2"]
        )

        XCTAssertFalse(visible)
    }
}

#if os(iOS)
@MainActor
final class IOSAppShellTests: XCTestCase {
    func testUIKitShellTabOrderMatchesAppContract() {
        XCTAssertEqual(IOSAppShellTab.allCases, [.library, .settings, .convert])
        XCTAssertEqual(IOSAppShellTab.allCases.map(\.systemImage), [
            "books.vertical",
            "gearshape",
            "wand.and.stars",
        ])
    }

    func testUIKitShellBuildsOneNavigationControllerPerTab() {
        let controller = IOSAppShellController(
            settings: AppSettings(),
            library: LibraryStore(),
            player: AudioPlayer(),
            playerPresentation: PlayerPresentation(),
            bookmarkStore: BookmarkStore(),
            readerCoordinator: ReaderCoordinator(),
            audioWarmup: AudioEngineWarmup()
        )

        let navigationControllers = controller.viewControllers as? [UINavigationController]
        XCTAssertEqual(navigationControllers?.count, IOSAppShellTab.allCases.count)
        XCTAssertEqual(
            navigationControllers?.compactMap(\.tabBarItem.title),
            IOSAppShellTab.allCases.map(\.title)
        )
    }
}
#endif
