#if os(iOS)
import SwiftUI
import UIKit

/// A UIPageViewController wrapper that provides Apple Books-style page
/// curl animations. Each "page" is a SwiftUI `AnyView` snapshot hosted
/// inside a `UIHostingController`.
///
/// The container is driven by an external page index binding — when the
/// binding changes programmatically (e.g. keyboard/tap), it animates to
/// the new page. User-initiated curl gestures update the binding on
/// completion.
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

        // Add center tap gesture for toggling chrome
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleCenterTap(_:)))
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

        // If the current displayed page differs from the binding, animate
        guard let current = pvc.viewControllers?.first as? IndexedHostingController,
              current.pageIndex != target else { return }

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

        // MARK: DataSource

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let vc = viewController as? IndexedHostingController else { return nil }
            let prev = vc.pageIndex - 1
            if prev >= 0 {
                return hostingController(for: prev)
            }
            // At page 0: signal host to load previous chapter.
            if parent.onPreviousChapter?() == true {
                parent.currentPage = 0
            }
            return nil
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let vc = viewController as? IndexedHostingController else { return nil }
            let next = vc.pageIndex + 1
            if next < parent.pages.count {
                return hostingController(for: next)
            }
            // At last page: signal host to load next chapter.
            if parent.onAdvanceChapter?() == true {
                parent.currentPage = 0
            }
            return nil
        }

        // MARK: Delegate

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
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

        // Handle swipe past first/last page for chapter navigation
        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            // No-op — we handle transitions in didFinishAnimating
        }

        // MARK: Center tap

        @objc func handleCenterTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let width = view.bounds.width
            let thirdWidth = width / 3.0

            if location.x < thirdWidth {
                // Left third — previous page (user-initiated, kill follow)
                let prev = parent.currentPage - 1
                if prev >= 0 {
                    parent.onUserPageChange?()
                    parent.currentPage = prev
                } else {
                    parent.onUserPageChange?()
                    _ = parent.onPreviousChapter?()
                }
            } else if location.x > thirdWidth * 2 {
                // Right third — next page (user-initiated, kill follow)
                let next = parent.currentPage + 1
                if next < parent.pages.count {
                    parent.onUserPageChange?()
                    parent.currentPage = next
                } else {
                    parent.onUserPageChange?()
                    _ = parent.onAdvanceChapter?()
                }
            } else {
                // Center third — toggle chrome only; not a page change.
                parent.onCenterTap?()
            }
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
