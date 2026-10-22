#if os(iOS)
import UIKit

/// Owns the native page animation and its overlapping-input lifetime.
/// Canonical offsets remain decisions of ReaderPaginatedTextLayout.
@MainActor
final class ReaderPageNavigation {
    private let view: UIView
    private let scrollView: UIScrollView
    private let pageUnderflowGuard: UIView
    private let pageOverflowGuard: UIView
    private let settings: AppSettings
    private let beforeSnapshot: () -> Void
    /// Prevents overlapping page renders/snapshots when the user taps the
    /// reader edges repeatedly while a page transition is still running.
    private var isPageTransitioning = false

    init(view: UIView, scrollView: UIScrollView, pageUnderflowGuard: UIView,
         pageOverflowGuard: UIView, settings: AppSettings, beforeSnapshot: @escaping () -> Void) {
        self.view = view
        self.scrollView = scrollView
        self.pageUnderflowGuard = pageUnderflowGuard
        self.pageOverflowGuard = pageOverflowGuard
        self.settings = settings
        self.beforeSnapshot = beforeSnapshot
    }

    func begin() -> Bool {
        guard !isPageTransitioning else { return false }
        isPageTransitioning = true
        return true
    }

    func settle() { isPageTransitioning = false }

    func setPageOffset(_ offset: CGPoint, forward: Bool, outgoingPage: UIView?) {
        guard !UIAccessibility.isReduceMotionEnabled,
              !ProcessInfo.processInfo.arguments.contains("-uiTestReduceMotion") else {
            scrollView.setContentOffset(offset, animated: false)
            isPageTransitioning = false
            return
        }
        switch settings.pageTurnStyle {
        case .none:
            scrollView.setContentOffset(offset, animated: false)
            isPageTransitioning = false
        case .slide:
            // Paginated mode is a page transition, not a vertical scroll.
            // Keep the scroll view as a layout container, move its offset
            // synchronously, and animate a snapshot horizontally. This also
            // prevents UIKit from exposing the intermediate vertical offset
            // when the reader is opened with everything else hidden.
            let frame = scrollView.convert(scrollView.bounds, to: view)
            scrollView.setContentOffset(offset, animated: false)
            guard let oldPage = outgoingPage else {
                isPageTransitioning = false
                return
            }
            oldPage.frame = frame
            view.addSubview(oldPage)
            scrollView.transform = CGAffineTransform(translationX: forward ? frame.width : -frame.width, y: 0)
            UIView.animate(withDuration: 0.35, delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
                oldPage.transform = CGAffineTransform(translationX: forward ? -frame.width : frame.width, y: 0)
                self.scrollView.transform = .identity
            } completion: { _ in
                oldPage.removeFromSuperview()
                self.isPageTransitioning = false
            }
        case .flip:
            performHorizontalPageCurl(to: offset, forward: forward, outgoingPage: outgoingPage)
        }
    }

    /// A horizontal page fold around the vertical reading edge. UIKit's
    /// built-in curl only travels vertically and `transitionFlip…` rotates
    /// like a card, so neither represents turning a book page.
    private func performHorizontalPageCurl(to offset: CGPoint, forward: Bool, outgoingPage: UIView?) {
        guard let outgoingPage else {
            scrollView.setContentOffset(offset, animated: false)
            isPageTransitioning = false
            return
        }

        let frame = scrollView.convert(scrollView.bounds, to: view)
        scrollView.setContentOffset(offset, animated: false)
        outgoingPage.frame = frame
        view.addSubview(outgoingPage)
        let turningPage: UIView
        if forward {
            turningPage = outgoingPage
        } else {
            // Keep the current page underneath while the previous page opens
            // from the spine. Snapshot the committed destination, not the old page.
            scrollView.layoutIfNeeded()
            guard let incomingPage = snapshotReaderPage(afterScreenUpdates: true) else {
                outgoingPage.removeFromSuperview()
                isPageTransitioning = false
                return
            }
            incomingPage.frame = frame
            turningPage = incomingPage
            view.addSubview(incomingPage)
        }
        turningPage.accessibilityIdentifier = "reader.pageCurl"
        turningPage.isAccessibilityElement = true
        turningPage.accessibilityLabel = "Page turning"
        turningPage.layer.isDoubleSided = false
        turningPage.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        turningPage.layer.position = CGPoint(x: frame.minX, y: frame.midY)

        let foldShadow = CAGradientLayer()
        foldShadow.frame = turningPage.bounds
        foldShadow.colors = [UIColor.black.withAlphaComponent(0.30).cgColor, UIColor.clear.cgColor]
        foldShadow.startPoint = CGPoint(x: 0, y: 0.5)
        foldShadow.endPoint = CGPoint(x: 1, y: 0.5)
        turningPage.layer.addSublayer(foldShadow)

        var fold = CATransform3DIdentity
        fold.m34 = -1 / 900
        fold = CATransform3DRotate(fold, -.pi / 2, 0, 1, 0)
        if !forward { turningPage.layer.transform = fold }
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            turningPage.layer.transform = forward ? fold : CATransform3DIdentity
            foldShadow.opacity = forward ? 1 : 0
        } completion: { _ in
            turningPage.removeFromSuperview()
            outgoingPage.removeFromSuperview()
            self.isPageTransitioning = false
        }
    }

    /// Edge masks live outside the scroll view. Carry them with its snapshot
    /// so a raw offset restored by a chrome transition cannot expose half a glyph.
    func snapshotReaderPage(afterScreenUpdates: Bool) -> UIView? {
        beforeSnapshot()
        guard let surface = scrollView.snapshotView(afterScreenUpdates: afterScreenUpdates) else { return nil }
        let viewport = scrollView.convert(scrollView.bounds, to: view)
        let page = UIView(frame: CGRect(origin: .zero, size: viewport.size))
        page.backgroundColor = scrollView.backgroundColor
        page.clipsToBounds = true
        surface.frame = page.bounds
        page.addSubview(surface)
        for mask in [pageUnderflowGuard, pageOverflowGuard] where !mask.isHidden {
            let cover = UIView(frame: mask.frame.offsetBy(dx: -viewport.minX, dy: -viewport.minY))
            cover.backgroundColor = mask.backgroundColor
            page.addSubview(cover)
        }
        return page
    }

}
#endif
