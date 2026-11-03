#if os(iOS)
import UIKit

/// Owns the collection view's physical lower boundary, independently of scroll insets.
@MainActor
final class LibraryGridViewport {
    private let bottom: NSLayoutConstraint

    init(grid: UIView, container: UIView) {
        bottom = grid.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        bottom.isActive = true
    }

    @discardableResult
    func update(in container: UIView, miniPlayerFrame: CGRect?) -> Bool {
        let safeFrame = container.safeAreaLayoutGuide.layoutFrame
        let lowerEdge: CGFloat
        if let miniPlayerFrame, !miniPlayerFrame.isEmpty,
           miniPlayerFrame.intersects(container.bounds) {
            lowerEdge = max(safeFrame.minY, miniPlayerFrame.minY)
        } else {
            lowerEdge = safeFrame.maxY
        }
        let constant = lowerEdge - container.bounds.maxY
        guard abs(bottom.constant - constant) > 0.5 else { return false }
        bottom.constant = constant
        return true
    }

    func updateForShell(_ controller: UIViewController) {
        var ancestor = controller.parent
        var frame: CGRect?
        while let current = ancestor {
            if let root = current as? IOSRootContainerController {
                frame = root.shellMiniPlayerFrame(in: controller.view)
                break
            }
            ancestor = current.parent
        }
        if update(in: controller.view, miniPlayerFrame: frame) {
            controller.view.layoutIfNeeded()
        }
    }
}
#endif
