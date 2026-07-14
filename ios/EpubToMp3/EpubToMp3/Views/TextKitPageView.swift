#if os(iOS)
import SwiftUI
import UIKit

/// Apple Books-style paginated reader backed by a **native TextKit page**
/// rather than a SwiftUI snapshot.
///
/// Each page is an `NSAttributedString` slice (already laid out by
/// `Paginator.paginateAttributed`, which uses the same TextKit stack a
/// `UITextView` uses). A page view controller hosts ONE `UITextView`
/// directly and is fed its slice from the `pages` array every time it
/// becomes the displayed / pending controller.
///
/// ## Why this replaces `PageCurlContainer`
///
/// The previous container wrapped every page in a SwiftUI `AnyView` →
/// `UIHostingController` and cached those controllers **by page index**.
/// The cache held the controller's content as an immutable identity, so a
/// re-pagination that produced a different page set with the same count
/// (front-matter / credits paginated first, real chapter text after) left
/// stale controllers in place — the user saw tap-to-advance interleave
/// with the credits page, flicker on every turn, and (when the content
/// hash was made sensitive enough to evict) the data source lost its
/// high-index controllers and a forward tap jumped to the NEXT CHAPTER.
///
/// Here there is no content identity cache. The controllers are reused
/// only as lightweight shells; their text is re-pushed from `pages[index]`
/// on every vend, so a page can never display a slice that no longer
/// belongs to it. The source of truth is always the `pages` array.
struct TextKitPageView: UIViewControllerRepresentable {
    /// The chapter's page slices, in order. Source of truth for content.
    var pages: [NSAttributedString]
    /// Identity of the chapter currently being displayed (the EPUB
    /// `chapter.id`). The DEFINITIVE signal that a chapter swap happened —
    /// independent of page count, which can coincide between two chapters and
    /// leave a count-based latch stuck. When this changes, the swap latch is
    /// cleared and the displayed page is re-seeded from the fresh `pages`.
    var chapterToken: String
    @Binding var currentPage: Int
    /// Column width / horizontal margin so the hosted text view lays out
    /// identically to how the paginator measured the slice.
    var columnWidth: CGFloat
    var margin: CGFloat
    /// Vertical insets reserving space for the host's chrome (top: status
    /// bar + nav/top bar; bottom: player bar + page-number footer). The
    /// paginator already sized each slice to fit `containerHeight - these`,
    /// so the text view must be pinned inside the same corridor or the
    /// first lines render under the status bar (clock / battery).
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// Opaque page background. A `.pageCurl` transition with
    /// `isDoubleSided == false` reveals whatever sits behind the curling
    /// page; a transparent page lets the previous page show through and
    /// the two pages' text visually merge. Must be the reader's theme
    /// colour so pages are opaque.
    var backgroundColor: UIColor
    /// Called when the user advances past the LAST page. Return `true` if
    /// a next chapter was loaded (host resets `currentPage` to 0).
    let onAdvanceChapter: (() -> Bool)?
    /// Called when the user retreats before page 0. Return `true` if a
    /// previous chapter was loaded.
    let onPreviousChapter: (() -> Bool)?
    /// Center-third tap (chrome toggle).
    var onCenterTap: (() -> Void)?
    /// Called when the user taps a link inside the page-curl text view.
    /// Return true when the reader handled the URL and UIKit should suppress
    /// its default external-open behaviour.
    var onLinkTap: ((URL) -> Bool)? = nil
    /// Sentence spans for the chapter currently displayed. Used to resolve a
    /// long-press's TextKit `characterIndex` to the `SentenceSpan` it falls
    /// inside, mirroring the scroll-mode tap-to-play feature (`ReaderView`'s
    /// `sentenceRow`). Empty when unavailable — the long-press then no-ops.
    var spans: [SentenceSpan] = []
    /// Called when the user long-presses a sentence on a page-curl page.
    /// Mirrors scroll mode's `onJumpToSentence`, which shows the "Tocar
    /// daqui" confirmation dialog.
    var onJumpToSentence: ((SentenceSpan) -> Void)? = nil
    /// Fires the moment a user-initiated page turn lands, so the host can
    /// clear audio auto-follow (otherwise the next audio tick yanks the
    /// reader back to the player's page).
    var onUserPageChange: (() -> Void)? = nil
    /// Fires at the start of a curl gesture so the host can suppress audio
    /// auto-follow during the animation.
    var onWillTransition: (() -> Void)? = nil
    /// Fires when a curl gesture ends (completed or not).
    var onDidFinishTransition: (() -> Void)? = nil
    /// Fires just before `onPreviousChapter`, so the host can arm its
    /// snap-to-last-page-of-previous-chapter mechanism.
    var onPreviousChapterNeedsLastPage: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue]
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.isDoubleSided = false

        let initial = context.coordinator.controller(for: clampedPage)
        pvc.setViewControllers([initial], direction: .forward, animated: false)
        // The initial chapter is already seeded — record its token so the
        // deferred-seed path doesn't fire a redundant re-seed on first update.
        context.coordinator.committedChapterToken = pages.isEmpty ? nil : chapterToken
        FlickerProbe.shared.log("makeUIViewController chapterToken=\(chapterToken) pages.count=\(pages.count) currentPage=\(currentPage == Int.max ? "MAX" : String(currentPage)) clampedPage=\(clampedPage) committedToken=\(context.coordinator.committedChapterToken ?? "nil")")

        // Tap recognizer on the PVC view so it fires regardless of the
        // hosted UITextView. Drives page turns directly via
        // setViewControllers — never writes `currentPage` before the
        // animation completes, avoiding the binding-write race.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        pvc.view.addGestureRecognizer(tap)

        // Edge-swipe recognizer for CHAPTER crossing. The page-curl PVC's own
        // pan turns pages WITHIN a chapter, but it silently refuses to swipe
        // past the last page / before the first (its data source returns nil
        // at the bounds), so a swipe at the boundary does nothing. This pan
        // runs simultaneously with the PVC's and only acts when there is no
        // neighbouring page in the swipe direction — i.e. the user is trying
        // to swipe OUT of the chapter — handing off to onAdvance/onPrevious.
        let edgePan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleEdgePan(_:))
        )
        edgePan.delegate = context.coordinator
        pvc.view.addGestureRecognizer(edgePan)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        let oldCount = coordinator.parent.pages.count
        let oldToken = coordinator.parent.chapterToken
        coordinator.parent = self

        let target = clampedPage
        FlickerProbe.shared.log("updateUIVC ENTRY chapterToken=\(chapterToken) oldToken=\(oldToken) pages.count=\(pages.count) oldCount=\(oldCount) currentPage=\(currentPage == Int.max ? "MAX" : String(currentPage)) target=\(target) committedToken=\(coordinator.committedChapterToken ?? "nil")")

        // DEFINITIVE chapter-swap signal: the chapter token changed. This is
        // independent of page count (two chapters can have the same count),
        // so it can never leave the swap latch stuck. The pool is purged so a
        // reused shell can't display the previous chapter's slice, the latch
        // is cleared, and the displayed page is re-seeded from the fresh
        // `pages` without animation. The host already reset `currentPage` to
        // the right page (0 on advance; last page on retreat) via
        // ReaderView.onChange(chapter.id).
        if chapterToken != oldToken {
            FlickerProbe.shared.log("updateUIVC BRANCH1(tokenChanged) pages.isEmpty=\(pages.isEmpty) target=\(target)")
            coordinator.committedChapterToken = nil
            // Keep the already-installed old controller on screen while the
            // new chapter is still unpaginated. It is a hold frame only: the
            // incoming chapter is never seeded from stale slices.
            guard !pages.isEmpty else {
                coordinator.isAwaitingChapterSwap = true
                return
            }
            coordinator.isAwaitingChapterSwap = false
            coordinator.purgePool()
            // The new chapter's final pages are already here — seed `target`
            // and mark this token as committed so a later same-token update
            // doesn't re-seed.
            let vc = coordinator.controller(for: target)
            if coordinator.seedCrossing(pvc, vc) {
                coordinator.committedChapterToken = chapterToken
            }
            return
        }

        // Same token as last update, but we never committed a seed for it
        // because `pages` was empty at swap time. Now that the fresh pages have
        // arrived, perform the deferred seed exactly once. This is the moment
        // the new chapter's content is first shown — no stale frame preceded it.
        if coordinator.committedChapterToken != chapterToken, !pages.isEmpty {
            FlickerProbe.shared.log("updateUIVC BRANCH2(deferredSeed) isTransitioning=\(coordinator.isTransitioning) target=\(target) currentPage=\(currentPage == Int.max ? "MAX" : String(currentPage))")
            // Never re-seed the queue while a pan / programmatic turn is live —
            // `setViewControllers` on a PVC mid-transition raises
            // NSInvalidArgumentException. Leave the token uncommitted so this
            // branch retries on the update SwiftUI fires after the transition
            // completes (the completion handlers below request one).
            guard !coordinator.isTransitioning else { return }
            coordinator.committedChapterToken = chapterToken
            coordinator.isAwaitingChapterSwap = false
            coordinator.purgePool()
            let vc = coordinator.controller(for: target)
            // Backward crossing (startAtLastPage): currentPage == Int.max means
            // makeUIViewController already seeded page 0 (pages were empty at that
            // point). The chapter-curl animation already happened via the swipe
            // gesture; we just need a hard cut to the last page with no additional
            // animation. seedCrossing would animate forward (or reverse) visibly
            // from page 0 → last — that is the "forced forward hop" the user sees.
            if currentPage == Int.max {
                FlickerProbe.shared.log("updateUIVC BRANCH2 hard-cut to target=\(target)")
                pvc.setViewControllers([vc], direction: .forward, animated: false)
            } else {
                // Deferred crossing seed: the new chapter's pages have now landed.
                // Animate the curl from the still-displayed OLD controller (the back
                // of the curl) to the new page — this is what removes the wrong-text
                // flash the user saw when this was a hard `animated: false` cut.
                coordinator.seedCrossing(pvc, vc)
            }
            return
        }

        // Page count changed within the SAME chapter (settings repagination).
        // Re-seed the displayed page from the fresh array.
        if pages.count != oldCount {
            FlickerProbe.shared.log("updateUIVC BRANCH3(countChanged) target=\(target) currentPage=\(currentPage == Int.max ? "MAX" : String(currentPage))")
            // Same crash guard: don't re-seed mid-transition. A repagination
            // that lands during a user pan re-runs on the next update once the
            // turn settles.
            guard !coordinator.isTransitioning else { return }
            coordinator.isAwaitingChapterSwap = false
            let vc = coordinator.controller(for: target)
            pvc.setViewControllers([vc], direction: .forward, animated: false)
            return
        }

        // Content may have been rebuilt with the same count (theme / colour
        // switch repopulates the rendered attributed string). Re-push the
        // visible controller's slice so the colour change lands. This is
        // cheap and correct: the hosted UITextView identity-gates the
        // assignment, so an unchanged slice is a no-op (no flicker).
        if let current = pvc.viewControllers?.first as? TextKitPageController {
            let changed = current.apply(
                slice: coordinator.slice(at: current.pageIndex),
                margin: margin, topInset: topInset, bottomInset: bottomInset,
                background: backgroundColor
            )
            // A content swap on the visible page WITHOUT a count change or a
            // user-driven index change is exactly the on-screen text-snap the
            // user reported. A pure colour/theme re-push (same string, new
            // attributes) is benign — `apply` returns `false` for an
            // identity-equal slice, so only a genuinely different slice is
            // counted.
            if changed { FlickerProbe.shared.record(.staleSlicePushed) }
        }

        // If the displayed page already matches the binding (e.g.
        // didFinishAnimating just wrote currentPage), skip the programmatic
        // setViewControllers — re-animating on a completed animation is the
        // classic flicker-to-page-0 race.
        guard let current = pvc.viewControllers?.first as? TextKitPageController,
              current.pageIndex != target else { return }
        // Never start a programmatic re-navigation while a turn (user or
        // tap) is mid-flight, or while a tap turn is between its
        // didFinishAnimating and its completion handler. Both windows would
        // re-navigate off a stale `currentPage` and fight the in-flight turn.
        guard !coordinator.isTransitioning, !coordinator.isProgrammaticTurn else { return }
        // A chapter swap was requested but the new pages haven't landed yet.
        // Re-navigating now would jump within the OLD chapter (visible flash);
        // wait for the count-change branch to re-seed against the new pages.
        guard !coordinator.isAwaitingChapterSwap else { return }

        let direction: UIPageViewController.NavigationDirection =
            target > current.pageIndex ? .forward : .reverse
        let vc = coordinator.controller(for: target)
        // A programmatic re-navigation from `updateUIViewController` is only
        // legitimate when an EXTERNAL driver moved the binding (audio
        // auto-follow, TOC jump, settings re-derive). Those set the new
        // index BEFORE this runs, so the guards above on `isTransitioning`
        // / `isProgrammaticTurn` already filtered out the turn-fighting
        // cases. Anything reaching here during a user-turn window would be
        // the flicker race — count it so the test can prove it's gone.
        if coordinator.isUserTurnWindowOpen {
            FlickerProbe.shared.record(.spuriousRenavigation)
        }
        pvc.setViewControllers([vc], direction: direction, animated: true)
    }

    private var clampedPage: Int { max(0, min(pages.count - 1, currentPage)) }

    // MARK: - Coordinator

    final class Coordinator: NSObject,
                             UIPageViewControllerDataSource,
                             UIPageViewControllerDelegate,
                             UIGestureRecognizerDelegate {
        var parent: TextKitPageView
        var isTransitioning = false
        /// True while a tap-to-turn `setViewControllers` is animating. A
        /// programmatic `setViewControllers` ALSO fires the
        /// `didFinishAnimating` delegate — without this flag that delegate
        /// would write `currentPage` a second time and re-run the
        /// chapter-advance check (with a previousViewControllers list that
        /// reflects the programmatic swap, not a user swipe), which made a
        /// "tap to go back" immediately bounce forward again. The completion
        /// handler on the tap's `setViewControllers` is the single source of
        /// truth for tap turns; the delegate must no-op for them.
        var isProgrammaticTurn = false
        /// Timestamp of the last user-initiated turn (tap or swipe). Used by
        /// `isUserTurnWindowOpen` to flag a programmatic re-navigation that
        /// lands within the post-turn settling window — the flicker race.
        private var lastUserTurnAt: Date = .distantPast
        /// True for a short window after a user turn, during which a
        /// programmatic `setViewControllers` would visibly fight the gesture.
        var isUserTurnWindowOpen: Bool {
            Date().timeIntervalSince(lastUserTurnAt) < 0.6
        }
        func markUserTurn() { lastUserTurnAt = Date() }
        /// True between requesting a chapter swap (forward past last page /
        /// back before page 0) and the host actually delivering the new
        /// chapter's `pages`. While armed, `updateUIViewController` must not
        /// programmatically re-navigate — the only legitimate next move is
        /// the count-change re-seed when the new chapter arrives.
        var isAwaitingChapterSwap = false
        /// Direction to animate the NEXT chapter-swap re-seed. Set at the exact
        /// moment the swap latch is armed (forward past last page → `.forward`;
        /// back before page 0 → `.reverse`), consumed EXACTLY once by
        /// `seedCrossing` and reset to nil. nil ⇒ the re-seed is not a user
        /// crossing (e.g. a TOC jump that happens to change chapter, or a
        /// settings repagination) ⇒ hard-cut with `animated: false`. Keeping the
        /// signal here avoids threading a direction through the host.
        var pendingCrossingDirection: UIPageViewController.NavigationDirection? = nil
        /// The chapter token for which a page has actually been seeded into the
        /// PVC. Lets the deferred-seed path fire exactly once when a swap
        /// happened while the new chapter's pages weren't ready yet (cache
        /// cleared) — without it, an empty-pages swap would never show the new
        /// chapter, or would re-seed on every subsequent update.
        var committedChapterToken: String?
        /// Lightweight controller shells reused by page index. The shells
        /// are reused only to avoid churning `UIViewController` objects;
        /// their TEXT is always re-pushed from `parent.pages` on vend, so
        /// no controller can display a slice that no longer belongs to its
        /// index. This is the core invariant that fixes the stale-page bug.
        private var pool: [Int: TextKitPageController] = [:]

        init(_ parent: TextKitPageView) { self.parent = parent }

        /// Drop all reused shells. Called on a chapter swap so the data
        /// source can't vend a controller still wired to the previous
        /// chapter's `pageIndex` (which, after the index space shrinks,
        /// could point past the new chapter's last page).
        func purgePool() { pool.removeAll() }

        /// The slice for `index`, or an empty string if out of range.
        func slice(at index: Int) -> NSAttributedString {
            parent.pages.indices.contains(index) ? parent.pages[index] : NSAttributedString()
        }

        /// Return the controller for `index`, freshly fed its current slice.
        func controller(for index: Int) -> TextKitPageController {
            let vc = pool[index] ?? {
                let c = TextKitPageController(pageIndex: index)
                c.onLinkTap = parent.onLinkTap
                c.spans = parent.spans
                c.onJumpToSentence = parent.onJumpToSentence
                pool[index] = c
                return c
            }()
            vc.pageIndex = index
            vc.onLinkTap = parent.onLinkTap
            vc.spans = parent.spans
            vc.onJumpToSentence = parent.onJumpToSentence
            vc.apply(
                slice: slice(at: index),
                margin: parent.margin,
                topInset: parent.topInset,
                bottomInset: parent.bottomInset,
                background: parent.backgroundColor
            )
            return vc
        }

        /// Seed the freshly-swapped chapter's page. When a crossing direction is
        /// armed (a real chapter turn), animate a page-curl in that direction so
        /// the crossing gets the same turn feel as an in-chapter turn — and so
        /// the still-displayed OLD controller becomes the BACK of the curl
        /// instead of a hard cut over stale text (that hard cut is the
        /// "wrong-page flash" the user saw). Otherwise (nil direction, or
        /// reduce-motion) hard-cut with `animated: false`.
        /// Seed the freshly-swapped chapter page. Returns `false` (a no-op)
        /// when a transition is already in flight — calling
        /// `setViewControllers` while the PVC is mid-pan (or mid programmatic
        /// turn) raises `NSInvalidArgumentException` inside
        /// `_validatedViewControllersForTransitionWithViewControllers` and
        /// aborts the process (observed SIGABRT from `_handlePanGesture`).
        /// The caller must NOT mark the token committed on a `false` return
        /// so the deferred-seed path re-fires on a later update once the
        /// transition has settled.
        @discardableResult
        func seedCrossing(_ pvc: UIPageViewController, _ vc: TextKitPageController) -> Bool {
            guard !isTransitioning else { return false }
            // NOTE: do NOT force `vc.view.frame`/`layoutIfNeeded()` here.
            // `UIPageViewController`'s pageCurl style owns child-view framing
            // via its own internal transition container (autoresizing-mask
            // based, predates Auto Layout containment) — a frame we assign
            // BEFORE `setViewControllers` installs the view gets silently
            // overwritten by the PVC's own layout pass without re-triggering
            // `layoutIfNeeded()` on our subtree. That left TextKit's glyph
            // layout cached against a stale, pre-install frame: text was
            // visible only while the curl animation was live (rendering the
            // pre-install snapshot) and disappeared the instant it settled at
            // the PVC's real installed frame. `TextKitPageController.
            // viewDidLayoutSubviews` (below) re-syncs the text view to
            // whatever frame the PVC actually lands on, on every layout pass
            // it triggers — including the post-curl one — without fighting
            // frame ownership.
            let dir = pendingCrossingDirection
            pendingCrossingDirection = nil          // consume exactly once
            guard let dir, !UIAccessibility.isReduceMotionEnabled else {
                pvc.setViewControllers([vc], direction: .forward, animated: false)
                return true
            }
            // Programmatic animated turn. Guard the delegate the same way
            // navigate() does: with isProgrammaticTurn set, didFinishAnimating
            // takes its early-return branch and does NOT write currentPage or
            // re-run the advance check — the host already owns currentPage
            // (0 on forward, last page on backward) via
            // ReaderView.onChange(chapter.id), so there is no second write.
            isTransitioning = true
            isProgrammaticTurn = true
            pvc.setViewControllers([vc], direction: dir, animated: true) { [weak self] _ in
                guard let self else { return }
                self.isTransitioning = false
                self.isProgrammaticTurn = false
            }
            return true
        }

        // MARK: Tap-to-turn

        func navigate(_ direction: UIPageViewController.NavigationDirection,
                      in pvc: UIPageViewController) {
            FlickerProbe.shared.log(
                "TextKit.navigate direction=\(direction) awaiting=\(isAwaitingChapterSwap) transitioning=\(isTransitioning)"
            )
            // A chapter crossing is in flight: the host has bumped the chapter
            // but the new `pages` haven't landed / been re-seeded yet, so the
            // displayed controller still carries the OLD chapter's
            // `pageIndex`. Acting on it now would (a) re-fire
            // onAdvance/onPrevious off the stale last/first page — skipping a
            // whole chapter on the second tap — or (b) navigate within the old
            // index space that's about to be torn down. Ignore the turn until
            // the swap settles (the token-change re-seed clears the latch).
            guard !isAwaitingChapterSwap else { return }
            guard !isTransitioning,
                  let current = pvc.viewControllers?.first as? TextKitPageController
            else { return }

            let nextIndex: Int
            switch direction {
            case .forward:
                let candidate = current.pageIndex + 1
                if candidate < parent.pages.count {
                    nextIndex = candidate
                } else {
                    // Crossing into the next chapter. Do NOT write
                    // `currentPage = 0` against the OLD `pages` here — that
                    // makes `updateUIViewController` re-navigate to page 0 of
                    // the CURRENT chapter (a visible flash) before the host's
                    // chapter swap repaginates. The host changes the chapter,
                    // and `ReaderView.onChange(chapter.id)` resets currentPage
                    // to 0 against the NEW pages. Arm the swap latch so a
                    // re-navigation in the meantime is suppressed.
                    // Arm the latch *before* changing SwiftUI state. The host
                    // callback can synchronously re-render and clear the latch;
                    // setting it afterwards leaves it stuck true, so the next
                    // backward tap is silently ignored.
                    pendingCrossingDirection = .forward
                    isAwaitingChapterSwap = true
                    if parent.onAdvanceChapter?() != true {
                        pendingCrossingDirection = nil
                        isAwaitingChapterSwap = false
                    }
                    return
                }
            case .reverse:
                let candidate = current.pageIndex - 1
                if candidate >= 0 {
                    nextIndex = candidate
                } else {
                    parent.onPreviousChapterNeedsLastPage?()
                    pendingCrossingDirection = .reverse
                    isAwaitingChapterSwap = true
                    if parent.onPreviousChapter?() != true {
                        pendingCrossingDirection = nil
                        isAwaitingChapterSwap = false
                    }
                    return
                }
            @unknown default:
                return
            }

            let vc = controller(for: nextIndex)
            parent.onUserPageChange?()
            markUserTurn()
            isTransitioning = true
            isProgrammaticTurn = true
            pvc.setViewControllers([vc], direction: direction, animated: true) { [weak self] completed in
                guard let self else { return }
                self.isTransitioning = false
                self.isProgrammaticTurn = false
                if completed { self.parent.currentPage = nextIndex }
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let pvc = gesture.view?.parentViewController as? UIPageViewController else { return }
            let location = gesture.location(in: gesture.view)
            let width = gesture.view?.bounds.width ?? 1
            let third = width / 3.0
            if location.x < third {
                navigate(.reverse, in: pvc)
            } else if location.x > third * 2 {
                navigate(.forward, in: pvc)
            } else {
                parent.onCenterTap?()
            }
        }

        /// Tracks whether the current edge-pan gesture has already triggered a
        /// chapter crossing, so a single continuous drag fires at most once.
        private var edgePanCrossed = false

        /// Horizontal edge-swipe → chapter crossing. Only fires when the user
        /// drags far enough in a direction that has NO neighbouring page (they
        /// are on the last page dragging left/forward, or the first page
        /// dragging right/backward). Within-chapter turns are left entirely to
        /// the PVC's own pan.
        @objc func handleEdgePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view,
                  let pvc = view.parentViewController as? UIPageViewController,
                  let current = pvc.viewControllers?.first as? TextKitPageController
            else { return }

            switch gesture.state {
            case .began:
                edgePanCrossed = false
            case .changed:
                guard !edgePanCrossed, !isTransitioning, !isAwaitingChapterSwap else { return }
                let translationX = gesture.translation(in: view).x
                // Require a deliberate horizontal drag (¼ width or 80 pt).
                let threshold = min(view.bounds.width * 0.25, 80)
                if translationX <= -threshold {
                    // Dragging forward (content moves left). Only cross if there
                    // is NO next page in this chapter — otherwise the PVC turns.
                    let atLastPage = current.pageIndex >= parent.pages.count - 1
                    if atLastPage {
                        edgePanCrossed = true
                        abortPVCCurl(pvc)
                        if parent.onAdvanceChapter?() == true {
                            pendingCrossingDirection = .forward
                            isAwaitingChapterSwap = true
                        }
                    }
                } else if translationX >= threshold {
                    // Dragging backward (content moves right).
                    let atFirstPage = current.pageIndex <= 0
                    if atFirstPage {
                        edgePanCrossed = true
                        abortPVCCurl(pvc)
                        parent.onPreviousChapterNeedsLastPage?()
                        if parent.onPreviousChapter?() == true {
                            pendingCrossingDirection = .reverse
                            isAwaitingChapterSwap = true
                        }
                    }
                }
            default:
                break
            }
        }

        /// Abort the page-curl that the PVC's own pan started at the boundary.
        /// When the user swipes past the last page, the PVC begins a curl that
        /// it will REVERT (its data source has no next page) — and that
        /// reverting curl, racing the chapter swap's instant re-seed, is the
        /// "wrong page flashes during the turn" the user saw. Bouncing the
        /// PVC's gesture recognizers (disable→enable) cancels the in-flight
        /// curl cleanly so only the new chapter's page 0 is presented.
        private func abortPVCCurl(_ pvc: UIPageViewController) {
            // Find the PVC's OWN pan (the page-curl driver), not our edge-pan.
            // The PVC's internal pans have no delegate set by us; our edge-pan
            // recognizer is the one whose delegate is this coordinator.
            for gr in pvc.view.gestureRecognizers ?? [] {
                guard gr is UIPanGestureRecognizer, gr.delegate !== self else { continue }
                gr.isEnabled = false
                gr.isEnabled = true
            }
        }

        // MARK: DataSource

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? TextKitPageController else { return nil }
            let prev = vc.pageIndex - 1
            guard prev >= 0 else { return nil }
            return controller(for: prev)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? TextKitPageController else { return nil }
            let next = vc.pageIndex + 1
            guard next < parent.pages.count else { return nil }
            return controller(for: next)
        }

        // MARK: Delegate

        func pageViewController(_ pvc: UIPageViewController,
                                willTransitionTo pending: [UIViewController]) {
            isTransitioning = true
            markUserTurn()
            parent.onWillTransition?()
        }

        func pageViewController(_ pvc: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            // Tap-to-turn drives its own `setViewControllers` with a
            // completion handler that owns `currentPage` AND the
            // `isTransitioning` reset. We must NOT clear `isTransitioning`
            // here for a programmatic turn: this delegate fires BEFORE the
            // completion handler, so clearing it now opens a window where
            // `updateUIViewController` sees the PVC already on the new page
            // while `currentPage` still holds the OLD index — it then
            // re-navigates in the opposite direction (the "tap back, bounce
            // forward" bug). Leave everything to the completion handler.
            if isProgrammaticTurn {
                parent.onDidFinishTransition?()
                return
            }
            isTransitioning = false
            parent.onDidFinishTransition?()
            guard completed,
                  let vc = pvc.viewControllers?.first as? TextKitPageController
            else { return }
            parent.onUserPageChange?()
            let landed = vc.pageIndex
            parent.currentPage = landed
            // NOTE: do NOT trigger chapter advance/retreat here. A native
            // swipe that LANDS on the last (or first) page is an ordinary
            // in-chapter navigation — the user arrived at the edge page, they
            // did not ask to leave the chapter. UIPageViewController already
            // refuses to swipe PAST the last page (its data source returns nil
            // beyond the bounds), so there is no "swiped past the end" signal
            // to act on. Previously `landed == pages.count - 1` fired
            // onAdvanceChapter the moment a swipe reached the last page, so on
            // a 2-page chapter a single forward swipe to page 2 jumped to the
            // next chapter and bounced currentPage back to 0. Chapter crossing
            // is handled deliberately by the tap path in `navigate(_:)`, which
            // only advances when the user taps forward while already ON the
            // last page (candidate >= pages.count).
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard g is UITapGestureRecognizer else { return true }
            let owner = touch.view?.parentViewController
            let controller = (owner as? TextKitPageController)
                ?? ((owner as? UIPageViewController)?.viewControllers?.first as? TextKitPageController)
            guard let controller else { return true }
            let touchesLink = controller.containsLink(at: touch.location(in: controller.view))
            if touchesLink {
                FlickerProbe.shared.log("TextKit.tap DEFERRED_TO_LINK page=\(controller.pageIndex)")
            }
            return !touchesLink
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// A page controller that owns a single `UITextView` and renders one
/// `NSAttributedString` slice. Carries its `pageIndex` so the page view
/// controller's data source can identify which page is on screen.
final class TextKitPageController: UIViewController, UITextViewDelegate {
    var pageIndex: Int
    var onLinkTap: ((URL) -> Bool)?
    /// Sentence spans for the chapter, used to resolve a long-press's
    /// character index to the sentence it falls inside.
    var spans: [SentenceSpan] = []
    /// Fires with the resolved sentence on a long-press. Mirrors scroll
    /// mode's tap-to-play ("Tocar daqui") flow.
    var onJumpToSentence: ((SentenceSpan) -> Void)?

    private let textView: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.maximumNumberOfLines = 0
        tv.adjustsFontForContentSizeCategory = false
        tv.dataDetectorTypes = []
        tv.showsVerticalScrollIndicator = false
        tv.showsHorizontalScrollIndicator = false
        return tv
    }()

    /// The attributed string currently displayed. Used to gate
    /// `apply(slice:)` on CONTENT equality, not pointer identity: every
    /// `ReaderView` re-render rebuilds the `pages` array, so the same page's
    /// slice arrives as a fresh `NSAttributedString` instance with identical
    /// content on each chrome toggle / settings tweak. Gating on identity
    /// re-assigned `textView.attributedText` every time → a full TextKit
    /// relayout → the 1-frame text-snap the user reported as flicker.
    /// Content equality makes those re-pushes true no-ops.
    private var assignedSlice: NSAttributedString?

    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!

    /// The plain string currently shown — exposed for tests asserting that
    /// a reused shell displays the right slice after a content swap.
    var debugSliceString: String { textView.attributedText?.string ?? "" }

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        // Pin to the RAW view edges. The vertical `topInset` / `bottomInset`
        // already fold in SwiftUI's safe-area insets (status bar / home
        // indicator) PLUS the host chrome — computed by `ReaderLayoutMath`
        // from values SwiftUI knows. We must NOT pin to
        // `safeAreaLayoutGuide` here: a UIKit child controller hosted under
        // SwiftUI frequently reports ZERO safe-area insets, which let text
        // render under the clock / battery on every page but the first.
        leadingConstraint = textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0)
        trailingConstraint = textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0)
        topConstraint = textView.topAnchor.constraint(equalTo: view.topAnchor, constant: 0)
        bottomConstraint = textView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0)
        NSLayoutConstraint.activate([leadingConstraint, trailingConstraint, topConstraint, bottomConstraint])

        // Long-press → resolve the pressed character to a `SentenceSpan` and
        // fire the same "Tocar daqui" flow scroll mode already has via
        // per-sentence `.onTapGesture`. A simple TAP is reserved for page
        // turn / chrome toggle (handled by the PVC-level tap recognizer in
        // `TextKitPageView.Coordinator`, which sits on `pvc.view` — a
        // DIFFERENT view than this text view — so it doesn't compete here).
        // `require(toFail:)` against the text view's own long-press-to-select
        // recognizer lets native text selection win when the user holds
        // longer / drags for a selection handle, while still letting our
        // handler fire first for a plain long-press-and-release. Preserves
        // link taps, which go through `shouldInteractWith url:` (a distinct,
        // higher-priority interaction) unaffected by this addition.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        textView.addGestureRecognizer(longPress)
        for existing in textView.gestureRecognizers ?? [] {
            guard existing !== longPress, existing is UILongPressGestureRecognizer else { continue }
            longPress.require(toFail: existing)
        }
    }

    /// `UIPageViewController`'s pageCurl style owns this view's frame via
    /// its own internal (autoresizing-mask-based) transition container —
    /// it can re-frame `view` at any point, including right after an
    /// animated curl settles onto this controller. Auto Layout resolves
    /// `textView`'s constraints against the new frame on its own next
    /// pass, but that alone left the hosted `UITextView`'s internal TextKit
    /// glyph geometry stale in practice: text rendered correctly only
    /// while the curl animation was live, then vanished once it settled at
    /// the PVC's real installed frame (a prior fix that force-set
    /// `view.frame` before installation made this WORSE by fighting the
    /// PVC's own frame ownership outright — reverted). Forcing a
    /// synchronous re-layout of just the text view on every real layout
    /// pass keeps it in sync with whatever frame is currently installed,
    /// without touching `view.frame` ourselves.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
    }

    /// Resolve `location` (in the text view's coordinate space) to a
    /// character index via TextKit, then find the `SentenceSpan` whose text
    /// contains a snippet of the rendered text around that index. Mirrors
    /// `ReaderView.pageIndexContaining(sentence:in:)`'s prefix-probe strategy
    /// (character offsets don't line up 1:1 between `SentenceSpan.startChar`,
    /// a plain-text offset, and the HTML-rendered `NSAttributedString` used
    /// here — probing by substring is what tolerates that mismatch).
    func sentenceSpan(at location: CGPoint) -> SentenceSpan? {
        guard !spans.isEmpty, textView.attributedText.length > 0 else { return nil }
        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        let glyphIndex = layoutManager.glyphIndex(for: location, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let boundingRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer
        )
        // Reject presses that land outside any glyph's bounding box (e.g. in
        // trailing whitespace below the last line) — `glyphIndex(for:in:)`
        // clamps to the nearest glyph even far off-screen.
        guard boundingRect.insetBy(dx: -20, dy: -20).contains(location) else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let fullText = textView.attributedText.string as NSString
        guard characterIndex < fullText.length else { return nil }

        // Snippet of rendered text straddling the press point, used as the
        // probe needle against each span's own text.
        let snippetStart = max(0, characterIndex - 20)
        let snippetLength = min(40, fullText.length - snippetStart)
        guard snippetLength > 0 else { return nil }
        let snippet = fullText.substring(with: NSRange(location: snippetStart, length: snippetLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else { return nil }
        // Use a short, punctuation-tolerant probe (first ~15 chars of the
        // snippet) so minor whitespace/markup differences between the span's
        // plain text and the rendered HTML don't defeat the match.
        let probe = String(snippet.prefix(15))
        guard !probe.isEmpty else { return nil }
        return spans.first { $0.text.range(of: probe) != nil }
    }

    /// Returns true only when `location` lands on a linked glyph. The page-level
    /// recognizer declines these touches, leaving UITextView to route internal
    /// EPUB links before a page turn or chrome toggle can consume the tap.
    func containsLink(at location: CGPoint) -> Bool {
        guard textView.attributedText.length > 0 else { return false }
        let point = view.convert(location, to: textView)
        let layoutManager = textView.layoutManager
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textView.textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return false }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textView.textContainer
        )
        guard glyphRect.insetBy(dx: -4, dy: -4).contains(point) else { return false }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textView.attributedText.length else { return false }
        return textView.attributedText.attribute(.link, at: characterIndex, effectiveRange: nil) != nil
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let location = gesture.location(in: textView)
        guard let span = sentenceSpan(at: location) else { return }
        onJumpToSentence?(span)
    }

    /// Push a slice plus layout corridor into the hosted text view.
    /// Identity-gates the attributed assignment so an unchanged slice (the
    /// paginator memo returns the same instance) does not trigger a
    /// redundant TextKit relayout (1-frame flicker). The page view is given
    /// an OPAQUE background so a curling page never reveals the page behind
    /// it (the "text merging" the user saw).
    /// - Returns: `true` if the attributed text actually changed (a new
    ///   slice was assigned), `false` if the call was an identity-equal
    ///   no-op. Callers use this to distinguish a benign re-push from a
    ///   visible content swap.
    @discardableResult
    func apply(slice attributed: NSAttributedString,
               margin: CGFloat,
               topInset: CGFloat,
               bottomInset: CGFloat,
               background: UIColor) -> Bool {
        loadViewIfNeeded()
        view.backgroundColor = background
        if leadingConstraint.constant != margin { leadingConstraint.constant = margin }
        if trailingConstraint.constant != -margin { trailingConstraint.constant = -margin }
        if topConstraint.constant != topInset { topConstraint.constant = topInset }
        if bottomConstraint.constant != -bottomInset { bottomConstraint.constant = -bottomInset }
        // Gate on CONTENT, not pointer identity. A fresh instance carrying
        // the same characters + attributes is a no-op: skip the assignment
        // so TextKit never relayouts an unchanged page (the flicker source).
        if let current = assignedSlice, current.isEqual(to: attributed) {
            return false
        }
        textView.attributedText = attributed
        assignedSlice = attributed
        return true
    }

    func textView(_ textView: UITextView,
                  shouldInteractWith url: URL,
                  in range: NSRange,
                  interaction: UITextItemInteraction) -> Bool {
        guard interaction == .invokeDefaultAction else { return false }
        if onLinkTap?(url) == true {
            return false
        }
        return true
    }
}

private extension UIView {
    var parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}
#endif
