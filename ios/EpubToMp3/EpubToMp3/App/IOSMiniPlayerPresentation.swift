#if os(iOS)
import UIKit

/// Owns overlay visibility animations independently of reader viewport tokens.
@MainActor
final class IOSMiniPlayerPresentation {
    private let transition: PlayerOverlayTransition

    init(view: UIView) {
        transition = PlayerOverlayTransition(view: view, style: .fade,
            duration: ReaderChromeTransitionMetrics.duration)
    }

    func setVisible(visible: Bool, animated: Bool = true) {
        transition.setVisible(visible, animated: animated)
    }

    func hideImmediately() {
        transition.hideImmediately()
    }

}
#endif
