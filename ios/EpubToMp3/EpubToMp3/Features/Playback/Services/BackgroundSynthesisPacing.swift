#if os(iOS)
import UIKit

/// iOS kills a process that keeps the CPU busy in the background (more than 80% of one core over 60 s). Local
/// Piper synthesis is pure CPU, so listening with the screen locked used to end with the app terminated and the
/// player back at 0:00. While the app is not in the foreground the Rust synthesis loop rests between segments to
/// stay at half a core; coming back to the foreground lifts the limit and synthesis runs at full speed again.
@MainActor
final class BackgroundSynthesisPacing {
    /// Well below the OS limit, and about the speed Piper needs to keep up with real-time playback.
    static let backgroundCPUPercent: UInt32 = 50

    private let setLimit: (UInt32) -> Void
    private let center: NotificationCenter
    private let isBackgrounded: () -> Bool
    private var observers: [NSObjectProtocol] = []
    private(set) var appliedPercent: UInt32 = 0

    init(center: NotificationCenter = .default,
         isBackgrounded: (() -> Bool)? = nil,
         setLimit: ((UInt32) -> Void)? = nil) {
        self.center = center
        // Resolved here, not as default arguments, which are evaluated outside the main actor.
        self.isBackgrounded = isBackgrounded ?? { UIApplication.shared.applicationState == .background }
        self.setLimit = setLimit ?? { percent in _ = ConverterFFIAdapter().setBackgroundCPULimit(percent: percent) }
    }

    func start() {
        guard observers.isEmpty else { return }
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(Self.backgroundCPUPercent) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(0) }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(0) }
            },
        ]
        apply(isBackgrounded() ? Self.backgroundCPUPercent : 0)
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers = []
        apply(0)
    }

    private func apply(_ percent: UInt32) {
        guard percent != appliedPercent else { return }
        appliedPercent = percent
        setLimit(percent)
    }
}
#endif
