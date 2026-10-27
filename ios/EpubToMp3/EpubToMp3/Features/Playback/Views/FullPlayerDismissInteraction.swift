#if os(iOS)
import UIKit

@MainActor
final class FullPlayerDismissInteraction: NSObject {
    private let view: UIView
    private let controls: () -> [UIView]
    private let onBegin: () -> Bool
    private let onCancel: () -> Void
    private let onDismiss: () -> Void
    private var isDragging = false
    private var initialTranslation: CGFloat = 0
    fileprivate lazy var gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

    init(view: UIView, controls: @escaping () -> [UIView], onBegin: @escaping () -> Bool,
         onCancel: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.view = view
        self.controls = controls
        self.onBegin = onBegin
        self.onCancel = onCancel
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
        case .began:
            beginDrag()
        case .changed:
            updateDrag(translation: translation.y)
        case .ended:
            finishDrag(translation: translation.y, velocity: velocity.y, cancelled: false)
        case .cancelled, .failed:
            finishDrag(translation: translation.y, velocity: velocity.y, cancelled: true)
        default:
            break
        }
    }

    func beginDrag() {
        isDragging = onBegin()
        initialTranslation = view.transform.ty
    }

    func updateDrag(translation: CGFloat) {
        guard isDragging, translation.isFinite else { return }
        let offset = UIAccessibility.isReduceMotionEnabled ? 0 : max(0, initialTranslation + translation)
        view.transform = CGAffineTransform(translationX: 0, y: offset)
    }

    func finishDrag(translation: CGFloat, velocity: CGFloat, cancelled: Bool) {
        guard isDragging else { return }
        isDragging = false
        if PlayerDismissalDecision.shouldDismiss(translation: Double(translation), velocity: Double(velocity), cancelled: cancelled) {
            // The presentation owner hides before resetting the transform.
            onDismiss()
        } else {
            onCancel()
        }
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
