#if os(iOS)
import UIKit

/// One owner for visibility, interruption and interactive restoration of an overlay.
@MainActor
final class PlayerOverlayTransition {
    enum Style: Equatable { case fade, sheet }
    private let view: UIView
    private let style: Style
    private let duration: TimeInterval
    private var visibility = VisibilityTransition()
    private var isInteracting = false

    init(view: UIView, style: Style, duration: TimeInterval = 0.3) {
        self.view = view
        self.style = style
        self.duration = duration
        view.isHidden = true
        view.alpha = 0
        view.accessibilityViewIsModal = false
    }

    func setVisible(_ visible: Bool, animated: Bool = true) {
        if isInteracting && visible { return }
        guard let request = visibility.request(visible: visible) else { return }
        isInteracting = false
        view.layoutIfNeeded()
        let reduced = UIAccessibility.isReduceMotionEnabled
        let offset = style == .sheet && !reduced ? view.bounds.height : 0
        if visible && view.isHidden {
            view.transform = CGAffineTransform(translationX: 0, y: offset)
            view.alpha = 0
        }
        if visible {
            view.isHidden = false
            view.accessibilityViewIsModal = style == .sheet
        }
        let animations = {
            self.view.alpha = visible ? 1 : 0
            self.view.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: offset)
        }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self, self.visibility.isCurrent(request) else { return }
            self.view.isHidden = !visible
            if !visible {
                self.view.transform = .identity
                self.view.accessibilityViewIsModal = false
            }
        }
        if animated && view.window != nil {
            UIView.animate(withDuration: reduced ? min(duration, 0.15) : duration, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                animations: animations, completion: completion)
        } else {
            UIView.performWithoutAnimation(animations)
            completion(true)
        }
    }

    func hideImmediately() {
        visibility.invalidate(keeping: false)
        isInteracting = false
        view.layer.removeAllAnimations()
        view.isHidden = true
        view.alpha = 0
        view.transform = .identity
        view.accessibilityViewIsModal = false
    }

    func beginInteraction() -> Bool {
        guard visibility.requestedVisibility == true, !view.isHidden else { return false }
        visibility.invalidate(keeping: true)
        isInteracting = true
        let presentation = view.layer.presentation()
        let transform = presentation?.affineTransform() ?? view.transform
        let alpha = presentation.map { CGFloat($0.opacity) } ?? view.alpha
        view.layer.removeAllAnimations()
        view.transform = transform
        view.alpha = alpha
        return true
    }

    func restoreAfterInteraction() {
        guard isInteracting else { return }
        isInteracting = false
        visibility.invalidate(keeping: nil)
        setVisible(true)
    }
}
#endif
