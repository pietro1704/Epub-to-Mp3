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
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        let oldCount = coordinator.parent.pages.count
        let oldToken = coordinator.parent.chapterToken
        coordinator.parent = self

        let target = clampedPage

        // DEFINITIVE chapter-swap signal: the chapter token changed. This is
        // independent of page count (two chapters can have the same count),
        // so it can never leave the swap latch stuck. The pool is purged so a
        // reused shell can't display the previous chapter's slice, the latch
        // is cleared, and the displayed page is re-seeded from the fresh
        // `pages` without animation. The host already reset `currentPage` to
        // the right page (0 on advance; last page on retreat) via
        // ReaderView.onChange(chapter.id).
        if chapterToken != oldToken {
            coordinator.isAwaitingChapterSwap = false
            coordinator.purgePool()
            coordinator.committedChapterToken = nil
            if !pages.isEmpty {
                // The new chapter's pages are already here — seed page `target`
                // and mark this token as committed so a later same-token update
                // doesn't re-seed.
                let vc = coordinator.controller(for: target)
                pvc.setViewControllers([vc], direction: .forward, animated: false)
                coordinator.committedChapterToken = chapterToken
            }
            // else: cache was cleared and the new chapter hasn't paginated yet.
            // Do NOT seed anything — seeding here would push stale/old content
            // (the wrong interleaved page). Wait for a later update with the
            // fresh `pages` (handled below once the token has "settled").
            return
        }

        // Same token as last update, but we never committed a seed for it
        // because `pages` was empty at swap time. Now that the fresh pages have
        // arrived, perform the deferred seed exactly once. This is the moment
        // the new chapter's content is first shown — no stale frame preceded it.
        if coordinator.committedChapterToken != chapterToken, !pages.isEmpty {
            coordinator.committedChapterToken = chapterToken
            coordinator.isAwaitingChapterSwap = false
            let vc = coordinator.controller(for: target)
            pvc.setViewControllers([vc], direction: .forward, animated: false)
            return
        }

        // Page count changed within the SAME chapter (settings repagination).
        // Re-seed the displayed page from the fresh array.
        if pages.count != oldCount {
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
                pool[index] = c
                return c
            }()
            vc.pageIndex = index
            vc.apply(
                slice: slice(at: index),
                margin: parent.margin,
                topInset: parent.topInset,
                bottomInset: parent.bottomInset,
                background: parent.backgroundColor
            )
            return vc
        }

        // MARK: Tap-to-turn

        func navigate(_ direction: UIPageViewController.NavigationDirection,
                      in pvc: UIPageViewController) {
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
                    if parent.onAdvanceChapter?() == true { isAwaitingChapterSwap = true }
                    return
                }
            case .reverse:
                let candidate = current.pageIndex - 1
                if candidate >= 0 {
                    nextIndex = candidate
                } else {
                    parent.onPreviousChapterNeedsLastPage?()
                    if parent.onPreviousChapter?() == true { isAwaitingChapterSwap = true }
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

            let prevIndex = (previousViewControllers.first as? TextKitPageController)?.pageIndex
            let forward = prevIndex.map { landed > $0 } ?? false
            let backward = prevIndex.map { landed < $0 } ?? false

            // Crossing a chapter boundary by swipe. Arm the swap latch
            // instead of writing currentPage=0 against the OLD pages — the
            // host swaps the chapter and ReaderView.onChange(chapter.id)
            // resets currentPage against the NEW pages. Writing 0 here would
            // re-navigate within the current chapter first (visible flash).
            if forward, landed == parent.pages.count - 1 {
                if parent.onAdvanceChapter?() == true { isAwaitingChapterSwap = true }
            } else if backward, landed == 0 {
                parent.onPreviousChapterNeedsLastPage?()
                if parent.onPreviousChapter?() == true { isAwaitingChapterSwap = true }
            }
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// A page controller that owns a single `UITextView` and renders one
/// `NSAttributedString` slice. Carries its `pageIndex` so the page view
/// controller's data source can identify which page is on screen.
final class TextKitPageController: UIViewController {
    var pageIndex: Int

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
