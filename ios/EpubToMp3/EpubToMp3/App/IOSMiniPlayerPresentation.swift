#if os(iOS)
import UIKit

/// Owns overlay visibility animations independently of reader viewport tokens.
@MainActor
final class IOSMiniPlayerPresentation {
    private let view: UIView
    private var initialized = false
    private var generationCounter: UInt64 = 0

    init(view: UIView) { self.view = view }

    func setVisible(visible: Bool, animated: Bool = true) {
        generationCounter &+= 1
        let generation = generationCounter
        let wasVisible = initialized && !view.isHidden
            && view.alpha > 0.01
        let changed = !initialized || wasVisible != visible
        initialized = true
        guard changed else { return }

        if visible {
            view.isHidden = false
            view.alpha = animated ? 0 : 1
        }

        let animations = {
            self.view.alpha = visible ? 1 : 0
        }
        let completion: (Bool) -> Void = { _ in
            guard generation == self.generationCounter else { return }
            if !visible {
                self.view.isHidden = true
            }
        }

        if animated {
            UIView.animate(
                withDuration: ReaderChromeTransitionMetrics.duration,
                delay: 0,
                options: ReaderChromeTransitionMetrics.animationOptions,
                animations: animations,
                completion: completion
            )
        } else {
            animations()
            completion(true)
        }
    }

    func hideImmediately() {
        view.layer.removeAllAnimations()
        view.alpha = 0
        view.isHidden = true
        initialized = true
    }

}
#endif
