import Foundation

struct MiniPlayerDismissal {
    private let defaults: UserDefaults
    private static let key = "player.dismissedMiniPlayerBooks.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isDismissed(bookID: String?) -> Bool {
        Set(defaults.stringArray(forKey: Self.key) ?? []).contains(bookID ?? "_none_")
    }

    func dismiss(bookID: String?) {
        var books = Set(defaults.stringArray(forKey: Self.key) ?? [])
        guard books.insert(bookID ?? "_none_").inserted else { return }
        defaults.set(books.sorted(), forKey: Self.key)
    }

    func dismiss(readingBookID: String?, playingBookID: String?) {
        let contexts = Set([readingBookID, playingBookID].compactMap { $0 })
        if contexts.isEmpty { dismiss(bookID: nil) }
        else { contexts.forEach { dismiss(bookID: $0) } }
    }

    func allowPlayback(bookID: String?) {
        var books = Set(defaults.stringArray(forKey: Self.key) ?? [])
        let removed = books.remove(bookID ?? "_none_") != nil
        let removedEmpty = books.remove("_none_") != nil
        guard removed || removedEmpty else { return }
        defaults.set(books.sorted(), forKey: Self.key)
    }

    static func shouldDismiss(distance: Double, velocity: Double, height: Double, cancelled: Bool) -> Bool {
        !cancelled && distance > 0 && (distance > max(32, height * 0.6) || (distance > 12 && velocity > 700))
    }
}

#if os(iOS)
import UIKit

@MainActor
final class MiniPlayerDismissGesture: NSObject, UIGestureRecognizerDelegate {
    private weak var view: UIView?
    var onDismiss: () -> Void
    private let pan = UIPanGestureRecognizer()

    init(view: UIView, onDismiss: @escaping () -> Void) {
        self.view = view
        self.onDismiss = onDismiss
        super.init()
        pan.addTarget(self, action: #selector(dragged(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        for tap in view.gestureRecognizers?.compactMap({ $0 as? UITapGestureRecognizer }) ?? [] {
            tap.require(toFail: pan)
        }
        view.accessibilityCustomActions = [UIAccessibilityCustomAction(name: L10n.string("player.dismissMiniPlayer"),
            target: self, selector: #selector(accessibleDismiss))]
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: view)
        return velocity.y > 0 && velocity.y > abs(velocity.x)
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        let distance = max(0, gesture.translation(in: view).y)
        switch gesture.state {
        case .changed: view.transform = CGAffineTransform(translationX: 0, y: distance)
        case .ended, .cancelled, .failed:
            let dismiss = MiniPlayerDismissal.shouldDismiss(distance: distance,
                velocity: gesture.velocity(in: view).y, height: view.bounds.height, cancelled: gesture.state != .ended)
            view.transform = .identity
            if dismiss { onDismiss() }
        default: break
        }
    }

    @objc private func accessibleDismiss() -> Bool { onDismiss(); return true }
}
#endif
