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
    let pages: [AnyView]
    @Binding var currentPage: Int
    let onAdvanceChapter: (() -> Bool)?
    let onPreviousChapter: (() -> Bool)?
    let onCenterTap: (() -> Void)?

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
        coordinator.parent = self

        let target = clampedPage

        // If pages array changed (settings change, chapter change), reset
        if pages.count != oldPageCount {
            coordinator.clearCache()
            let vc = coordinator.hostingController(for: target)
            pvc.setViewControllers([vc], direction: .forward, animated: false)
            return
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
        private var cachedControllers: [Int: IndexedHostingController] = [:]

        init(_ parent: PageCurlContainer) {
            self.parent = parent
        }

        func clearCache() {
            cachedControllers.removeAll()
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
            // At page 0: try going to previous chapter
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
            // At last page: try going to next chapter
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
                // Left third — previous page
                let prev = parent.currentPage - 1
                if prev >= 0 {
                    parent.currentPage = prev
                } else {
                    _ = parent.onPreviousChapter?()
                }
            } else if location.x > thirdWidth * 2 {
                // Right third — next page
                let next = parent.currentPage + 1
                if next < parent.pages.count {
                    parent.currentPage = next
                } else {
                    _ = parent.onAdvanceChapter?()
                }
            } else {
                // Center third — toggle chrome
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
            // Our tap should wait for the page curl pan to fail
            otherGestureRecognizer is UIPanGestureRecognizer
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
