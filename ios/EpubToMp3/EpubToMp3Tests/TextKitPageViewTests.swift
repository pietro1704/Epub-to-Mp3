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
        chapterToken: String = "ch",
        onAdvanceChapter: (() -> Bool)? = nil,
        onPreviousChapter: (() -> Bool)? = nil,
        onCenterTap: (() -> Void)? = nil
    ) -> TextKitPageView {
        TextKitPageView(
            pages: pages,
            chapterToken: chapterToken,
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

    /// Regression: advancing past the last page arms the chapter-swap latch
    /// (instead of writing currentPage=0 against the old pages). The latch
    /// must NOT stay stuck — a chapter token change is the definitive clear
    /// signal. Here we assert the navigate path arms it and that `purgePool`
    /// + clearing works, mirroring what `updateUIViewController` does on a
    /// token change.
    func testForwardOnLastPageArmsSwapLatchAndTokenChangeClearsIt() {
        var binding = 1
        var advanceCalled = false
        let view = makeView(
            pages: pages(["p0", "p1"]),
            currentPage: .init(get: { binding }, set: { binding = $0 }),
            chapterToken: "chA",
            onAdvanceChapter: { advanceCalled = true; return true }
        )
        let coord = TextKitPageView.Coordinator(view)
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        // Seed the PVC on the LAST page, then tap forward.
        pvc.setViewControllers([coord.controller(for: 1)], direction: .forward, animated: false)
        coord.navigate(.forward, in: pvc)

        XCTAssertTrue(advanceCalled, "forward past the last page must request chapter advance")
        XCTAssertTrue(coord.isAwaitingChapterSwap, "advancing across the boundary must arm the swap latch")
        XCTAssertEqual(binding, 1, "currentPage must NOT be reset against the old chapter's pages")

        // Simulate the token-change handling: latch clears, pool purges.
        coord.isAwaitingChapterSwap = false
        coord.purgePool()
        XCTAssertFalse(coord.isAwaitingChapterSwap, "a chapter token change must clear the swap latch")
    }

    /// Reverse before page 0 must also arm the latch (so the host can swap to
    /// the previous chapter) and never bounce within the current chapter.
    func testReverseBeforePageZeroArmsSwapLatch() {
        var binding = 0
        var prevCalled = false
        var needsLastPageCalled = false
        var view = makeView(
            pages: pages(["p0", "p1"]),
            currentPage: .init(get: { binding }, set: { binding = $0 }),
            onPreviousChapter: { prevCalled = true; return true }
        )
        view.onPreviousChapterNeedsLastPage = { needsLastPageCalled = true }
        let coord = TextKitPageView.Coordinator(view)
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        pvc.setViewControllers([coord.controller(for: 0)], direction: .forward, animated: false)
        coord.navigate(.reverse, in: pvc)

        XCTAssertTrue(needsLastPageCalled, "retreat before page 0 must arm last-page landing")
        XCTAssertTrue(prevCalled, "retreat before page 0 must request previous chapter")
        XCTAssertTrue(coord.isAwaitingChapterSwap, "retreating across the boundary must arm the swap latch")
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

    /// Regression: a native swipe that LANDS on the last page is an ordinary
    /// in-chapter navigation — the user arrived at the edge, they did not ask
    /// to leave the chapter. `didFinishAnimating` must NOT advance the chapter
    /// just because the landed page is the last one. (The old
    /// `landed == pages.count - 1` check made a single forward swipe on a
    /// 2-page chapter jump to the next chapter and bounce currentPage to 0.)
    func testSwipeLandingOnLastPageDoesNotAdvanceChapter() {
        var binding = 0
        var advanceCalled = false
        let view = makeView(
            pages: pages(["p0", "p1"]),       // 2-page chapter
            currentPage: .init(get: { binding }, set: { binding = $0 }),
            onAdvanceChapter: { advanceCalled = true; return true }
        )
        let coord = TextKitPageView.Coordinator(view)
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        // Simulate a user swipe that landed on the LAST page (index 1) from
        // page 0 — NOT a programmatic turn.
        let last = coord.controller(for: 1)
        pvc.setViewControllers([last], direction: .forward, animated: false)
        coord.isProgrammaticTurn = false
        coord.pageViewController(pvc, didFinishAnimating: true,
                                 previousViewControllers: [coord.controller(for: 0)],
                                 transitionCompleted: true)
        XCTAssertEqual(binding, 1, "landing on the last page must set currentPage to that page")
        XCTAssertFalse(advanceCalled,
                       "arriving on the last page by swipe must NOT advance to the next chapter")
        XCTAssertFalse(coord.isAwaitingChapterSwap,
                       "no chapter swap should be armed by an in-chapter swipe to the last page")
    }

    /// Edge-swipe forward on the LAST page crosses to the next chapter. The
    /// PVC's own pan can't (no page after the last), so the dedicated edge-pan
    /// recognizer hands off to onAdvanceChapter. A mid-chapter page must NOT
    /// trigger it (the PVC turns the page instead).
    func testEdgeSwipeForwardOnLastPageCrossesChapter() {
        var binding = 1
        var advanceCalled = false
        let view = makeView(
            pages: pages(["p0", "p1"]),          // last page is index 1
            currentPage: .init(get: { binding }, set: { binding = $0 }),
            onAdvanceChapter: { advanceCalled = true; return true }
        )
        let coord = TextKitPageView.Coordinator(view)
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        host.addSubview(pvc.view)
        pvc.view.frame = host.bounds
        pvc.setViewControllers([coord.controller(for: 1)], direction: .forward, animated: false)

        let pan = StubPan(view: pvc.view)
        pan.stubState = .began
        coord.handleEdgePan(pan)
        pan.stubState = .changed
        pan.stubTranslation = CGPoint(x: -200, y: 0)   // strong forward drag
        coord.handleEdgePan(pan)

        XCTAssertTrue(advanceCalled, "edge-swipe forward on the last page must advance the chapter")
        XCTAssertTrue(coord.isAwaitingChapterSwap, "crossing must arm the swap latch")
    }

    func testEdgeSwipeOnMiddlePageDoesNotCrossChapter() {
        var binding = 1
        var advanceCalled = false
        let view = makeView(
            pages: pages(["p0", "p1", "p2"]),    // index 1 is a middle page
            currentPage: .init(get: { binding }, set: { binding = $0 }),
            onAdvanceChapter: { advanceCalled = true; return true }
        )
        let coord = TextKitPageView.Coordinator(view)
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        host.addSubview(pvc.view)
        pvc.view.frame = host.bounds
        pvc.setViewControllers([coord.controller(for: 1)], direction: .forward, animated: false)

        let pan = StubPan(view: pvc.view)
        pan.stubState = .began; coord.handleEdgePan(pan)
        pan.stubState = .changed
        pan.stubTranslation = CGPoint(x: -200, y: 0)
        coord.handleEdgePan(pan)

        XCTAssertFalse(advanceCalled,
                       "an edge-swipe on a middle page must let the PVC turn the page, not cross chapters")
    }

    /// Regression (SIGABRT `NSInvalidArgumentException` from
    /// `_validatedViewControllersForTransitionWithViewControllers`):
    /// `seedCrossing` MUST NOT call `setViewControllers` while a transition
    /// is already in flight — doing so mid-pan crashes the process. It must
    /// return `false` and leave the displayed controller untouched, so the
    /// caller keeps the chapter token UNcommitted and retries after the turn.
    func testSeedCrossingNoOpsDuringActiveTransition() {
        var binding = 0
        let view = makeView(pages: pages(["p0", "p1"]),
                            currentPage: .init(get: { binding }, set: { binding = $0 }))
        let coord = TextKitPageView.Coordinator(view)
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        let seeded = coord.controller(for: 0)
        pvc.setViewControllers([seeded], direction: .forward, animated: false)

        // A pan / turn is live.
        coord.isTransitioning = true
        let didSeed = coord.seedCrossing(pvc, coord.controller(for: 1))

        XCTAssertFalse(didSeed, "seedCrossing must be a no-op while a transition is in flight")
        XCTAssertTrue((pvc.viewControllers?.first as? TextKitPageController) === seeded,
                      "the displayed controller must be unchanged — no mid-transition setViewControllers")
        // pendingCrossingDirection must be preserved (not consumed) so the
        // deferred retry animates in the originally-armed direction.
        coord.pendingCrossingDirection = .forward
        coord.isTransitioning = true
        _ = coord.seedCrossing(pvc, coord.controller(for: 1))
        XCTAssertEqual(coord.pendingCrossingDirection, .forward,
                       "a blocked seed must not consume the armed crossing direction")
    }

    /// Once the transition clears, the same `seedCrossing` call succeeds and
    /// swaps the displayed controller — proving the deferral is a delay, not
    /// a permanent drop of the chapter swap.
    func testSeedCrossingSucceedsAfterTransitionClears() {
        var binding = 0
        let view = makeView(pages: pages(["p0", "p1"]),
                            currentPage: .init(get: { binding }, set: { binding = $0 }))
        let coord = TextKitPageView.Coordinator(view)
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        pvc.setViewControllers([coord.controller(for: 0)], direction: .forward, animated: false)

        coord.isTransitioning = false            // turn finished
        let target = coord.controller(for: 1)
        let didSeed = coord.seedCrossing(pvc, target)   // nil direction ⇒ hard cut

        XCTAssertTrue(didSeed, "a seed with no active transition must succeed")
        XCTAssertTrue((pvc.viewControllers?.first as? TextKitPageController) === target,
                      "the displayed controller must now be the freshly-seeded page")
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

/// A `UIPanGestureRecognizer` whose `state` and `translation(in:)` can be
/// driven from a test, so the edge-pan chapter-crossing handler can be
/// exercised without a live touch session.
private final class StubPan: UIPanGestureRecognizer {
    var stubState: UIGestureRecognizer.State = .possible
    var stubTranslation: CGPoint = .zero
    private weak var stubView: UIView?

    init(view: UIView) {
        stubView = view
        super.init(target: nil, action: nil)
    }

    override var state: UIGestureRecognizer.State {
        get { stubState }
        set { stubState = newValue }
    }
    override var view: UIView? { stubView }
    override func translation(in v: UIView?) -> CGPoint { stubTranslation }
}
#endif
