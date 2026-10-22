#if os(iOS)
import UIKit

enum ReaderChromeTransitionMetrics {
    static let duration: TimeInterval = 0.28
    static let animationOptions: UIView.AnimationOptions = [
        .curveEaseInOut,
        .beginFromCurrentState,
        .allowUserInteraction,
    ]
}

#endif
