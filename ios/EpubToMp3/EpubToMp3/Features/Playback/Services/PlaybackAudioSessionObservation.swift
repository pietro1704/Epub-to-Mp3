import Foundation

/// Owns exact notification registrations independently of audio activation.
/// Its pending asynchronous reset cannot escape invalidation or replacement.
@MainActor
final class PlaybackAudioSessionObservation {
    struct Names: Sendable {
        let interruption: Notification.Name
        let routeChange: Notification.Name
        let mediaServicesReset: Notification.Name
        let interruptionTypeKey: String
        let interruptionOptionsKey: String
        let routeChangeReasonKey: String
    }
    private let center: NotificationCenter
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var registrationID: UUID?

    init(center: NotificationCenter = .default) { self.center = center }
    deinit { invalidate() }

    func install(names: Names, object: AnyObject,
                 interruption: @escaping @MainActor (UInt?, UInt) -> Void,
                 routeChange: @escaping @MainActor (Int?) -> Void,
                 reset: @escaping @MainActor () -> Void) {
        guard tokens.isEmpty else { return }
        let identity = UUID()
        registrationID = identity
        tokens.append(center.addObserver(forName: names.interruption, object: object, queue: .main) { note in
            let type = (note.userInfo?[names.interruptionTypeKey] as? NSNumber)?.uintValue
            let options = (note.userInfo?[names.interruptionOptionsKey] as? NSNumber)?.uintValue ?? 0
            MainActor.assumeIsolated { interruption(type, options) }
        })
        tokens.append(center.addObserver(forName: names.routeChange, object: object, queue: .main) { note in
            let reason = (note.userInfo?[names.routeChangeReasonKey] as? NSNumber)?.intValue
            MainActor.assumeIsolated { routeChange(reason) }
        })
        tokens.append(center.addObserver(forName: names.mediaServicesReset, object: object, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.registrationID == identity else { return }
                reset()
            }
        })
    }

    nonisolated func invalidate() {
        registrationID = nil
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}
