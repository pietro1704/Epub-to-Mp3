#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import EpubToMp3

/// Regression suite for the native TextKit page-turn engine that replaced
/// `PageCurlContainer`. The old container cached one SwiftUI-hosted
/// controller per page index and keyed the cache on a fragile content
/// version; a re-pagination that produced a different page set with the
/// same count (front-matter / credits first, real chapter text after) left
/// stale controllers in place. Symptoms the user hit on Pinocchio:
/// tap-to-advance interleaved with the first / credits page, flicker on
/// every turn, and a forward tap jumping to the NEXT CHAPTER.
///
/// `TextKitPageView` removes the content-identity cache: controllers are
/// reused only as shells and their text is ALWAYS re-pushed from the
/// `pages` array on vend, so a controller can never show a slice that no
/// longer belongs to its index.
@MainActor
final class TextKitPageViewTests: XCTestCase {

    private func makeView(
        pages: [NSAttributedString],
        currentPage: Binding<Int>,
        onAdvanceChapter: (() -> Bool)? = nil,
        onPreviousChapter: (() -> Bool)? = nil,
        onCenterTap: (() -> Void)? = nil
    ) -> TextKitPageView {
        TextKitPageView(
            pages: pages,
            currentPage: currentPage,
            columnWidth: 320,
            margin: 16,
            topInset: 0,
            bottomInset: 0,
            backgroundColor: .white,
            onAdvanceChapter: onAdvanceChapter,
            onPreviousChapter: onPreviousChapter,
            onCenterTap: onCenterTap
        )
    }

    private func pages(_ strings: [String]) -> [NSAttributedString] {
        strings.map { NSAttributedString(string: $0) }
    }

    /// A controller vended for an index always shows that index's CURRENT
    /// slice — even after the pages array is swapped for new content of the
    /// same count. This is the direct regression for the stale-page bug.
    func testControllerAlwaysShowsCurrentSliceAfterContentSwap() {
        var binding = 0
        let creditsPages = pages(["Carlo Collodi", "Proprietà letteraria"])
        let view = makeView(pages: creditsPages, currentPage: .init(get: { binding }, set: { binding = $0 }))
        let coord = TextKitPageView.Coordinator(view)

        // Warm the shell for page 0 with the credits content.
        let c0 = coord.controller(for: 0)
        c0.loadViewIfNeeded()

        // Swap to the real chapter content (same count).
        coord.parent = makeView(pages: pages(["C'era una volta", "un pezzo di legno"]),
                                currentPage: .init(get: { binding }, set: { binding = $0 }))
        let reused = coord.controller(for: 0)

        XCTAssertTrue(reused === c0, "the shell should be reused, not rebuilt")
        XCTAssertEqual(reused.debugSliceString, "C'era una volta",
                       "the reused controller must display the NEW slice for its index, not the stale credits page")
    }

    /// Advancing forward one page moves exactly one index — never skips to
    /// the next chapter while there are pages remaining.
    func testForwardAdvancesExactlyOnePage() {
        var binding = 0
        var advanceCalled = false
        let view = makeView(
            pages: pages(["p0", "p1", "p2"]),
            currentPage: .init(get: { binding }, set: { binding = $0 }),
            onAdvanceChapter: { advanceCalled = true; return true }
        )
        let coord = TextKitPageView.Coordinator(view)
        let next = coord.controller(for: 1)
        XCTAssertEqual(next.pageIndex, 1)
        XCTAssertFalse(advanceCalled, "advancing within a chapter must not delegate to chapter advance")
    }

    /// The data source returns nil past the last page (so a forward tap on
    /// the last page delegates chapter advance) and nil before page 0.
    func testDataSourceBoundaries() {
        var binding = 0
        let view = makeView(pages: pages(["p0", "p1"]), currentPage: .init(get: { binding }, set: { binding = $0 }))
        let coord = TextKitPageView.Coordinator(view)
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)

        let last = coord.controller(for: 1)
        XCTAssertNil(coord.pageViewController(pvc, viewControllerAfter: last),
                     "there is no page after the last one — forward must fall through to chapter advance")
        let first = coord.controller(for: 0)
        XCTAssertNil(coord.pageViewController(pvc, viewControllerBefore: first),
                     "there is no page before page 0 — reverse must fall through to chapter retreat")
        // Middle pages resolve to neighbours.
        XCTAssertEqual((coord.pageViewController(pvc, viewControllerAfter: first) as? TextKitPageController)?.pageIndex, 1)
        XCTAssertEqual((coord.pageViewController(pvc, viewControllerBefore: last) as? TextKitPageController)?.pageIndex, 0)
    }

    /// Regression ("tap to go back, then it bounces forward"): a
    /// programmatic tap-turn `setViewControllers` ALSO fires the
    /// `didFinishAnimating` delegate. That delegate must no-op while
    /// `isProgrammaticTurn` is set — otherwise it writes `currentPage` a
    /// second time and re-runs the boundary check off the programmatic
    /// swap, bouncing the page forward again.
    func testProgrammaticTurnSuppressesDidFinishDelegate() {
        var binding = 2
        var advanceCalled = false
        let view = makeView(
            pages: pages(["p0", "p1", "p2"]),
            currentPage: .init(get: { binding }, set: { binding = $0 }),
            onAdvanceChapter: { advanceCalled = true; return true }
        )
        let coord = TextKitPageView.Coordinator(view)
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        // Simulate the state right after a tap-turn kicked off its
        // setViewControllers: programmatic flag set, landed on the last page.
        coord.isProgrammaticTurn = true
        let last = coord.controller(for: 2)
        pvc.setViewControllers([last], direction: .forward, animated: false)
        coord.pageViewController(pvc, didFinishAnimating: true,
                                 previousViewControllers: [coord.controller(for: 1)],
                                 transitionCompleted: true)
        XCTAssertFalse(advanceCalled,
                       "didFinishAnimating must not trigger chapter advance for a programmatic tap turn")
    }

    /// Out-of-range index yields an empty slice rather than crashing.
    func testSliceOutOfRangeIsEmpty() {
        var binding = 0
        let view = makeView(pages: pages(["only"]), currentPage: .init(get: { binding }, set: { binding = $0 }))
        let coord = TextKitPageView.Coordinator(view)
        XCTAssertEqual(coord.slice(at: 5).length, 0)
        XCTAssertEqual(coord.slice(at: 0).string, "only")
    }
}
#endif
