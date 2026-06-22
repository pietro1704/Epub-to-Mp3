import XCTest
@testable import EpubToMp3

/// Regression tests for library gesture conflicts:
/// - Long press must NOT simultaneously open the book (tap leak).
/// - Tap must open the book without triggering the remove dialog.
final class LibraryGestureTests: XCTestCase {

    // MARK: - Long-press / tap exclusivity

    func testBookTileUsesExclusiveGesture() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Views/LibraryView.swift")
        )
        XCTAssertTrue(
            source.contains("ExclusiveGesture("),
            "BookTile must use ExclusiveGesture so a long-press cancels the tap and does not open the book."
        )
    }

    func testLongPressIsFirstInExclusiveGesture() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Views/LibraryView.swift")
        )
        // LongPressGesture must come BEFORE TapGesture inside ExclusiveGesture
        // so SwiftUI resolves long-press first and cancels the tap recogniser.
        let exclusiveRange = source.range(of: "ExclusiveGesture(")!
        let afterExclusive = String(source[exclusiveRange.upperBound...])
        let longPressPos = afterExclusive.range(of: "LongPressGesture")?.lowerBound
        let tapPos = afterExclusive.range(of: "TapGesture")?.lowerBound
        XCTAssertNotNil(longPressPos, "LongPressGesture must be present in ExclusiveGesture.")
        XCTAssertNotNil(tapPos, "TapGesture must be present in ExclusiveGesture.")
        if let lp = longPressPos, let tp = tapPos {
            XCTAssertTrue(lp < tp, "LongPressGesture must appear before TapGesture in ExclusiveGesture.")
        }
    }

    func testBookTileIsNotAButtonWithSimultaneousLongPress() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Views/LibraryView.swift")
        )
        // The old pattern (Button + .simultaneousGesture(LongPress)) caused
        // both the open-book tap and the long-press dialog to fire together.
        XCTAssertFalse(
            source.contains(".simultaneousGesture(") && source.contains("LongPressGesture"),
            "LibraryView must not use .simultaneousGesture for LongPress on book tiles — use ExclusiveGesture instead."
        )
    }
}
