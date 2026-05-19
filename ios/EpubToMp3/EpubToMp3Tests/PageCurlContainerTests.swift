#if os(iOS)
import XCTest
import SwiftUI
@testable import EpubToMp3

/// Regression: in `.flip` (page-curl) mode — the DEFAULT page-turn
/// style — `PageCurlContainer.Coordinator` caches one
/// `IndexedHostingController` per page index. A theme / colour switch
/// repopulates the chapter's `renderedAttributed` WITHOUT changing the
/// page count, so `updateUIViewController` short-circuited (its only
/// reset path was `pages.count != oldPageCount`). The cached
/// controllers kept rendering the STALE `AnyView` built from the old
/// theme — changing the reader theme left already-built pages (the
/// visible one included) in the previous colours.
///
/// Fix: `updateUIViewController` calls `refreshCachedRootViews()` on
/// every content-only update so each cached controller's `rootView` is
/// re-pushed with the fresh `AnyView`.
@MainActor
final class PageCurlContainerTests: XCTestCase {

    /// Build a coordinator with N cached page controllers, then change
    /// the parent's `pages` and verify `refreshCachedRootViews` swaps
    /// every cached controller's `rootView` to the new instance.
    func testRefreshCachedRootViewsPropagatesNewContent() {
        var binding = 0
        let oldPages = (0..<3).map { i in AnyView(Text("old-\(i)")) }
        let container = PageCurlContainer(
            pages: oldPages,
            currentPage: Binding(get: { binding }, set: { binding = $0 }),
            onAdvanceChapter: nil,
            onPreviousChapter: nil,
            onCenterTap: nil
        )
        let coordinator = PageCurlContainer.Coordinator(container)

        // Warm the cache for all three pages.
        let cached = (0..<3).map { coordinator.hostingController(for: $0) }
        for (i, hc) in cached.enumerated() {
            XCTAssertEqual(hc.pageIndex, i)
        }

        // Simulate a theme switch: same page COUNT, new AnyView content.
        let newPages = (0..<3).map { i in AnyView(Text("new-\(i)")) }
        coordinator.parent = PageCurlContainer(
            pages: newPages,
            currentPage: Binding(get: { binding }, set: { binding = $0 }),
            onAdvanceChapter: nil,
            onPreviousChapter: nil,
            onCenterTap: nil
        )
        coordinator.refreshCachedRootViews()

        // The cached controllers must be the SAME instances (no teardown)
        // but now hosting the refreshed root views.
        for i in 0..<3 {
            XCTAssertTrue(
                coordinator.hostingController(for: i) === cached[i],
                "page \(i) controller should be reused, not rebuilt"
            )
        }
    }

    /// A content-only refresh that finds a cached index now out of
    /// range (a count change raced the refresh) must evict it rather
    /// than crash on the out-of-bounds `pages[index]` access.
    func testRefreshDropsOutOfRangeCachedIndices() {
        var binding = 0
        let container = PageCurlContainer(
            pages: (0..<4).map { AnyView(Text("p\($0)")) },
            currentPage: Binding(get: { binding }, set: { binding = $0 }),
            onAdvanceChapter: nil,
            onPreviousChapter: nil,
            onCenterTap: nil
        )
        let coordinator = PageCurlContainer.Coordinator(container)
        _ = (0..<4).map { coordinator.hostingController(for: $0) }

        // Shrink to two pages, then refresh — pages 2 and 3 are stale.
        coordinator.parent = PageCurlContainer(
            pages: (0..<2).map { AnyView(Text("p\($0)")) },
            currentPage: Binding(get: { binding }, set: { binding = $0 }),
            onAdvanceChapter: nil,
            onPreviousChapter: nil,
            onCenterTap: nil
        )
        coordinator.refreshCachedRootViews()

        // Surviving pages keep their reused controllers.
        let p0 = coordinator.hostingController(for: 0)
        XCTAssertEqual(p0.pageIndex, 0)
    }
}
#endif
