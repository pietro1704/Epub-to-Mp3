#if os(iOS)
import UIKit

/// Adds only the overlap UIKit has not already included in the content safe area.
/// This owns no reader geometry, page position or scroll offset.
@MainActor
final class MiniPlayerScrollClearance {
    private var contribution: CGFloat = 0
    private var applying = false

    func update(_ controller: UIViewController, occlusion: CGRect?) {
        guard let view = controller.viewIfLoaded, !applying else { return }
        let original = max(0, controller.additionalSafeAreaInsets.bottom - contribution)
        let contentBottom = view.bounds.maxY - view.safeAreaInsets.bottom + contribution
        let overlap: CGFloat
        if let occlusion, !occlusion.isEmpty, occlusion.intersects(view.bounds) {
            overlap = max(0, contentBottom - occlusion.minY)
        } else { overlap = 0 }
        let next = original + overlap
        contribution = overlap
        guard abs(controller.additionalSafeAreaInsets.bottom - next) > 0.5 else { return }
        applying = true
        controller.additionalSafeAreaInsets.bottom = next
        applying = false
    }

    func updateForShell(_ controller: UIViewController) {
        var ancestor = controller.parent
        while let current = ancestor {
            if let root = current as? IOSRootContainerController {
                update(controller, occlusion: root.shellMiniPlayerFrame(in: controller.view))
                return
            }
            ancestor = current.parent
        }
        update(controller, occlusion: nil)
    }
}
#endif
