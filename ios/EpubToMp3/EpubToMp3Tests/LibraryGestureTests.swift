import XCTest
@testable import EpubToMp3

/// Regression tests for library gesture conflicts:
/// - Long press must NOT simultaneously open the book (tap leak).
/// - Tap must open the book without triggering the remove dialog.
final class LibraryGestureTests: XCTestCase {

    private func source() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Views/LibraryView.swift")
        )
    }

    // MARK: - Long-press / tap exclusivity

    /// Long press must use .highPriorityGesture so SwiftUI cancels the
    /// tap recogniser before it fires. The old ExclusiveGesture approach
    /// let taps complete on touchUp while the long-press was still pending.
    func testBookTileUsesHighPriorityGestureForLongPress() throws {
        let src = try source()
        XCTAssertTrue(
            src.contains("highPriorityGesture("),
            "BookTile must use .highPriorityGesture for LongPress so tap is suppressed."
        )
        XCTAssertTrue(
            src.contains("LongPressGesture"),
            "LongPressGesture must be present inside .highPriorityGesture."
        )
    }

    /// The guard flag `longPressConsumed` must be present so an
    /// onTapGesture that fires after a long-press is a no-op.
    func testLongPressConsumedFlagPresent() throws {
        let src = try source()
        XCTAssertTrue(
            src.contains("longPressConsumed"),
            "LibraryView must use a longPressConsumed flag to suppress tap after long-press."
        )
    }

    /// The old Button + .simultaneousGesture(LongPress) pattern caused
    /// both actions to fire together — must not be re-introduced.
    func testBookTileIsNotButtonWithSimultaneousLongPress() throws {
        let src = try source()
        XCTAssertFalse(
            src.contains(".simultaneousGesture(") && src.contains("LongPressGesture"),
            "LibraryView must not use .simultaneousGesture for LongPress — use .highPriorityGesture instead."
        )
    }

    /// ExclusiveGesture was the previous (broken) implementation.
    /// Ensure it is not re-introduced.
    func testExclusiveGestureIsNotUsed() throws {
        let src = try source()
        XCTAssertFalse(
            src.contains("ExclusiveGesture("),
            "ExclusiveGesture allowed tap to fire during long-press. Use .highPriorityGesture instead."
        )
    }
}
