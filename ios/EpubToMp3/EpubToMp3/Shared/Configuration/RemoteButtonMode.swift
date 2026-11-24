import Foundation

/// What the external next / previous buttons do (car head units, headphones, lock screen, Control Center).
/// `chapter` is the long-standing behaviour; `skip` turns them into the configured ±N-second skips, which is what a
/// plain head unit that only sends track commands needs while listening to a book.
enum RemoteButtonMode: String, CaseIterable {
    case chapter
    case skip

    static let storageKey = "playbackRemoteButtonMode"

    enum Resolution: Equatable {
        case chapter(forward: Bool)
        /// Signed seconds: positive skips forward, negative backward.
        case skip(TimeInterval)
    }

    static func stored(in defaults: UserDefaults = .standard) -> RemoteButtonMode {
        RemoteButtonMode(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .chapter
    }

    func resolve(forward: Bool, forwardSeconds: Double, backwardSeconds: Double) -> Resolution {
        switch self {
        case .chapter: return .chapter(forward: forward)
        case .skip: return .skip(forward ? forwardSeconds : -backwardSeconds)
        }
    }

    var title: String {
        L10n.string(self == .chapter ? "settings.remoteButtons.chapter" : "settings.remoteButtons.skip")
    }
}
