#if os(iOS)
import SwiftUI
import UIKit

/// A UIPageViewController wrapper that provides Apple Books-style page
/// curl animations. Each "page" is a SwiftUI `AnyView` snapshot hosted
/// inside a `UIHostingController`.
///
/// The container is driven by an external page index binding — when the
/// binding changes programmatically (e.g. keyboard), it animates to the
/// new page. User-initiated curl gestures and tap-to-turn update the
/// binding on completion via `didFinishAnimating`.
///
/// IMPORTANT — tap-to-turn vs binding conflict:
/// Page turns triggered by tapping the left/right thirds must go through
/// the PVC directly (via `pageViewController(_:viewControllerAfter:)`)
/// rather than writing `currentPage` and waiting for `updateUIViewController`
/// to call `setViewControllers`. Writing the binding while the PVC is
/// mid-animation causes "flicker between page 1 and current":
///   1. Tap fires → binding write → updateUIViewController → setViewControllers (animated)
///   2. That setViewControllers races the PVC's own in-flight animation
///   3. PVC snaps to page 0 briefly before settling on the correct page
/// Fix: the tap recognizer installed in `makeUIViewController` calls
/// `navigateByTap` on the coordinator, which calls `setViewControllers`
/// directly with the PVC's dataSource-supplied VC and only writes
/// `currentPage` in `didFinishAnimating` (same path as native swipe).
struct PageCurlContainer: UIViewControllerRepresentable {
    // `var` (not `let`) so a content-only refresh can swap the page
    // array on a coordinator's cached `parent` — see
    // `Coordinator.refreshCachedRootViews()` and its regression test.
    var pages: [AnyView]
    @Binding var currentPage: Int
    /// Monotonically increasing identity for the page CONTENT. When this
    /// value changes (e.g. theme / font / render-version bump) the
    /// coordinator pushes the fresh `AnyView` into every cached hosting
    /// controller. When it does NOT change, the cached `AnyView` is kept
    /// as-is — without this gate every re-render of the parent (e.g.
    /// `currentPage` write after curl completes) would re-push a brand
    /// new `AnyView` into the visible hosting controller and force its
    /// `UITextView` to re-layout, producing a 1-frame flicker at the
    /// tail of every page flip.
    var contentVersion: Int = 0
    let onAdvanceChapter: (() -> Bool)?
    let onPreviousChapter: (() -> Bool)?
    let onCenterTap: (() -> Void)?
    var chromeVisible: Bool = true
    /// Fires the moment a *user-initiated* page change lands — either
    /// `didFinishAnimating(completed: true)` from a curl gesture or a
    /// tap on the left/right third zone. The host clears `isFollowing`
    /// here so the audio's auto-follow modifier doesn't immediately
    /// revert `currentPage` to the page that contains the active
    /// sentence (user-visible symptom: "swipe / tap, page snaps back"
    /// during playback). Programmatic page changes — `setViewControllers`
    /// driven by `updateUIViewController` — never call this.
    var onUserPageChange: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue]
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.isDoubleSided = false

        // Set initial page
        let initial = context.coordinator.hostingController(for: clampedPage)
        pvc.setViewControllers([initial], direction: .forward, animated: false)

        // Tap recognizer for page-turn and chrome toggle.
        // This lives on the PVC view (not inside the hosted SwiftUI page)
        // so it fires regardless of what the UITextView inside the page
        // does. The coordinator's `navigateByTap` drives the PVC directly
        // via setViewControllers — it never writes `currentPage` before
        // the animation completes, preventing the binding-write race that
        // caused the "flicker between page 1 and current" bug.
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
        let oldPageCount = coordinator.parent.pages.count
        let oldContentVersion = coordinator.lastSeenContentVersion
        coordinator.parent = self

        let target = clampedPage

        // If pages array changed (settings change, chapter change), reset
        if pages.count != oldPageCount {
            coordinator.clearCache()
            coordinator.lastSeenContentVersion = contentVersion
            let vc = coordinator.hostingController(for: target)
            pvc.setViewControllers([vc], direction: .forward, animated: false)
            return
        }

        // Page COUNT is unchanged but the page CONTENT may have been
        // rebuilt — e.g. a theme/colour switch repopulates
        // `renderedAttributed` without altering the layout, so the
        // paginator yields the same number of pages with different
        // attributes. Only refresh when `contentVersion` advances; a
        // bare re-render with the same version means the visible
        // `AnyView` is structurally identical and re-pushing would
        // force a needless `UITextView` re-layout (visible as a
        // 1-frame flicker at the end of every page curl, because
        // `didFinishAnimating` writes `currentPage`).
        if contentVersion != oldContentVersion {
            coordinator.lastSeenContentVersion = contentVersion
            coordinator.refreshCachedRootViews()
        }

        // If the current displayed page already matches the binding
        // (e.g. didFinishAnimating just wrote currentPage after a native
        // swipe or a tap-to-turn), skip the programmatic setViewControllers
        // entirely. This is the core guard that breaks the race: without it
        // the binding write → updateUIViewController → setViewControllers
        // path would re-animate on top of an already-completed animation.
        guard let current = pvc.viewControllers?.first as? IndexedHostingController,
              current.pageIndex != target else { return }

        // Guard against attempting to animate while a transition is already
        // in progress. isTransitioning is true between willTransitionTo and
        // didFinishAnimating — a second setViewControllers during that window
        // is the primary cause of the flicker-to-page-1 bug.
        guard !coordinator.isTransitioning else { return }

        let direction: UIPageViewController.NavigationDirection =
            target > current.pageIndex ? .forward : .reverse
        let vc = coordinator.hostingController(for: target)
        pvc.setViewControllers([vc], direction: direction, animated: true)
    }

    private var clampedPage: Int {
        max(0, min(pages.count - 1, currentPage))
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject,
                              UIPageViewControllerDataSource,
                              UIPageViewControllerDelegate,
                              UIGestureRecognizerDelegate {
        var parent: PageCurlContainer
        /// Last `contentVersion` the coordinator has reconciled into the
        /// cached hosting controllers. Compared against the incoming
        /// `parent.contentVersion` in `updateUIViewController` so a
        /// no-op re-render (e.g. `currentPage` write at curl completion)
        /// skips `refreshCachedRootViews()` and the visible UITextView
        /// does not re-layout.
        var lastSeenContentVersion: Int = 0
        /// True between `willTransitionTo` and `didFinishAnimating`.
        /// Guards `updateUIViewController` from firing a second
        /// `setViewControllers` while one is already in progress.
        var isTransitioning: Bool = false
        private var cachedControllers: [Int: IndexedHostingController] = [:]

        init(_ parent: PageCurlContainer) {
            self.parent = parent
            self.lastSeenContentVersion = parent.contentVersion
        }

        func clearCache() {
            cachedControllers.removeAll()
        }

        /// Re-push the latest `AnyView` for every page that already has
        /// a cached `IndexedHostingController`. Called on a content-only
        /// update (page count unchanged) so a theme / render-version
        /// change recolours pages without tearing the page-curl stack
        /// down. Indices that fall outside the new `pages` range are
        /// dropped — they can only exist transiently if a count change
        /// raced this path.
        func refreshCachedRootViews() {
            for (index, controller) in cachedControllers {
                guard parent.pages.indices.contains(index) else {
                    cachedControllers.removeValue(forKey: index)
                    continue
                }
                controller.rootView = parent.pages[index]
            }
        }

        func hostingController(for index: Int) -> IndexedHostingController {
            if let existing = cachedControllers[index] {
                return existing
            }
            let view = parent.pages.indices.contains(index) ? parent.pages[index] : AnyView(EmptyView())
            let hc = IndexedHostingController(rootView: view, pageIndex: index)
            hc.view.backgroundColor = .clear
            cachedControllers[index] = hc
            return hc
        }

        // MARK: - Tap-to-turn

        /// Navigate forward or backward by one page directly through the
        /// PVC, without writing `currentPage` before the animation
        /// completes. This mirrors how native swipe/curl gestures work and
        /// avoids the binding-write race that caused flicker.
        func navigateByTap(direction: UIPageViewController.NavigationDirection,
                           in pvc: UIPageViewController) {
            guard !isTransitioning,
                  let current = pvc.viewControllers?.first as? IndexedHostingController
            else { return }

            let nextIndex: Int
            switch direction {
            case .forward:
                let candidate = current.pageIndex + 1
                if candidate < parent.pages.count {
                    nextIndex = candidate
                } else {
                    // Last page — delegate chapter advance to host
                    if parent.onAdvanceChapter?() == true {
                        parent.currentPage = 0
                    }
                    return
                }
            case .reverse:
                let candidate = current.pageIndex - 1
                if candidate >= 0 {
                    nextIndex = candidate
                } else {
                    // First page — delegate chapter retreat to host
                    if parent.onPreviousChapter?() == true {
                        parent.currentPage = 0
                    }
                    return
                }
            @unknown default:
                return
            }

            let vc = hostingController(for: nextIndex)
            parent.onUserPageChange?()
            pvc.setViewControllers([vc], direction: direction, animated: true) { [weak self] completed in
                guard completed, let self else { return }
                self.parent.currentPage = nextIndex
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let pvc = gesture.view?.next as? UIPageViewController
                        ?? gesture.view?.parentViewController as? UIPageViewController
            else { return }

            let location = gesture.location(in: gesture.view)
            let width = gesture.view?.bounds.width ?? 1
            let third = width / 3.0

            if location.x < third {
                navigateByTap(direction: .reverse, in: pvc)
            } else if location.x > third * 2 {
                navigateByTap(direction: .forward, in: pvc)
            } else {
                // Center third — toggle chrome only
                parent.onCenterTap?()
            }
        }

        // MARK: DataSource

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let vc = viewController as? IndexedHostingController else { return nil }
            let prev = vc.pageIndex - 1
            guard prev >= 0 else { return nil }
            return hostingController(for: prev)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let vc = viewController as? IndexedHostingController else { return nil }
            let next = vc.pageIndex + 1
            guard next < parent.pages.count else { return nil }
            return hostingController(for: next)
        }

        // MARK: Delegate

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            isTransitioning = false
            guard completed,
                  let vc = pageViewController.viewControllers?.first as? IndexedHostingController
            else { return }
            // Clear auto-follow BEFORE writing `currentPage` so the
            // host's `.onChange(of: currentSentenceId)` handler can't
            // race the next audio tick and yank the reader back to
            // the player's page.
            parent.onUserPageChange?()
            parent.currentPage = vc.pageIndex
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Allow our tap to work alongside the page curl gesture
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
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

/// UIHostingController subclass that carries a page index so the
/// UIPageViewController data source can identify which page is displayed.
final class IndexedHostingController: UIHostingController<AnyView> {
    let pageIndex: Int

    init(rootView: AnyView, pageIndex: Int) {
        self.pageIndex = pageIndex
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}
#endif
