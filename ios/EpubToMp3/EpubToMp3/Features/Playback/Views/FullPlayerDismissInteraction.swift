#if os(iOS)
import UIKit

@MainActor
final class FullPlayerDismissInteraction: NSObject {
    private let view: UIView
    private let controls: () -> [UIView]
    private let onDismiss: () -> Void
    fileprivate lazy var gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

    init(view: UIView, controls: @escaping () -> [UIView], onDismiss: @escaping () -> Void) {
        self.view = view
        self.controls = controls
        self.onDismiss = onDismiss
        super.init()
    }

    func install() {
        gesture.delegate = self
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
    }

    func acceptsTouch(at location: CGPoint) -> Bool {
        for control in controls() where !control.isHidden {
            let frameInView = control.convert(control.bounds, to: view)
            if frameInView.contains(location) {
                return false
            }
        }
        return true
    }

    @objc
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .changed:
            // Only downward drags are meaningful — there's nowhere "more
            // full" to go, so upward translation is clamped to zero.
            let clampedY = max(0, translation.y)
            view.transform = CGAffineTransform(translationX: 0, y: clampedY)

        case .ended, .cancelled:
            let dismissDistanceThreshold: CGFloat = 120
            let dismissVelocityThreshold: CGFloat = 800
            let shouldDismiss = translation.y > dismissDistanceThreshold || velocity.y > dismissVelocityThreshold

            guard shouldDismiss else {
                resetTransformToIdentity(animated: !UIAccessibility.isReduceMotionEnabled, velocity: velocity.y)
                return
            }

            if UIAccessibility.isReduceMotionEnabled {
                // Snap instead of sliding when the user has asked for less
                // motion — the dismissal itself still happens immediately.
                view.transform = .identity
                onDismiss()
            } else {
                UIView.animate(
                    withDuration: 0.25,
                    delay: 0,
                    options: [.curveEaseIn],
                    animations: {
                        self.view.transform = CGAffineTransform(translationX: 0, y: self.view.bounds.height)
                    },
                    completion: { [weak self] _ in
                        guard let self else { return }
                        self.onDismiss()
                        // `IOSRootContainer.refreshOverlayState()` only toggles
                        // isHidden/alpha and never resets transform, so this
                        // view must restore its own resting transform here —
                        // otherwise it reappears off-screen next time it's shown.
                        self.view.transform = .identity
                    }
                )
            }

        default:
            break
        }
    }

    private func resetTransformToIdentity(animated: Bool, velocity: CGFloat) {
        guard animated else {
            view.transform = .identity
            return
        }
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: abs(velocity) / 1000,
            options: [.allowUserInteraction],
            animations: {
                self.view.transform = .identity
            }
        )
    }

}

extension FullPlayerDismissInteraction: UIGestureRecognizerDelegate {
    /// Rejects touches that land on the scrubber, transport buttons, volume
    /// slider, or AirPlay button so `gesture` never competes with
    /// their own gesture/target-action handling — only `gesture`
    /// itself is filtered here; any other recognizer is left untouched.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === gesture else { return true }
        let location = touch.location(in: view)
        return acceptsTouch(at: location)
    }
}

#endif
