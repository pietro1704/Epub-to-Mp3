#if os(iOS)
import Foundation

/// Keeps NotificationCenter tokens outside the view controller's MainActor
/// isolation so cleanup remains valid even when ARC releases the controller
/// from a nonisolated context.
final class TocNotificationObserverBag {
    private var observers: [NSObjectProtocol] = []

    func append(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    deinit {
        observers.forEach { observer in
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

#endif
