import XCTest
@testable import EpubToMp3

final class LibrarySearchBehaviorTests: XCTestCase {
    func testScrollDownHidesSearchBar() {
        XCTAssertFalse(
            LibrarySearchVisibilityReducer.nextValue(
                isVisible: true,
                lastOffset: 0,
                offset: -24
            )
        )
    }

    func testScrollUpShowsSearchBar() {
        XCTAssertTrue(
            LibrarySearchVisibilityReducer.nextValue(
                isVisible: false,
                lastOffset: -80,
                offset: -48
            )
        )
    }

    func testSmallScrollDoesNotToggleSearchBar() {
        XCTAssertTrue(
            LibrarySearchVisibilityReducer.nextValue(
                isVisible: true,
                lastOffset: -40,
                offset: -44
            )
        )
        XCTAssertFalse(
            LibrarySearchVisibilityReducer.nextValue(
                isVisible: false,
                lastOffset: -40,
                offset: -44
            )
        )
    }

    func testReturningToTopShowsSearchBar() {
        XCTAssertTrue(
            LibrarySearchVisibilityReducer.nextValue(
                isVisible: false,
                lastOffset: -100,
                offset: 0
            )
        )
    }

    func testLibrarySearchUsesSharedGridInsetAndAccessibilityContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let librarySource = try String(contentsOf: root.appendingPathComponent("EpubToMp3/Features/Library/Views/LibraryView.swift"))
        let searchSource = try String(contentsOf: root.appendingPathComponent("EpubToMp3/Features/Library/Views/LibrarySearchBar.swift"))
        XCTAssertTrue(librarySource.contains(".padding(.horizontal, 16)"))
        XCTAssertFalse(searchSource.contains(".padding(.horizontal, 20)"))
        XCTAssertTrue(searchSource.contains("accessibilityIdentifier(\"library.searchBar\")"))
    }
}
