import Foundation

/// Explicit, process-local consent for temporary backend request correlation.
/// Neither activation nor its authorization tokens are stored on disk.
final class StreamingDiagnosticsSession: @unchecked Sendable {
    static let shared = StreamingDiagnosticsSession()
    private static let lifetimeNanoseconds: UInt64 = 300_000_000_000

    struct Authorization: Sendable {
        let journeyID: UUID
        private let activationID: UUID
        private let session: StreamingDiagnosticsSession

        fileprivate init(journeyID: UUID, activationID: UUID, session: StreamingDiagnosticsSession) {
            self.journeyID = journeyID
            self.activationID = activationID
            self.session = session
        }

        /// A stopped, expired, or replaced activation cannot authorize a GET.
        var isValid: Bool { session.isValid(activationID) }
    }

    private let lock = NSLock()
    private let clock: () -> UInt64
    private var activation: (id: UUID, startedAt: UInt64)?

    init(clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.clock = clock
    }

    @discardableResult
    func activate() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let identifier = UUID()
        activation = (identifier, clock())
        return identifier
    }

    func deactivate() {
        lock.lock()
        defer { lock.unlock() }
        activation = nil
    }

    var isActive: Bool { remainingTime > 0 }

    var remainingTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(remainingNanosecondsLocked()) / 1_000_000_000
    }

    func authorization(for journeyID: UUID) -> Authorization? {
        lock.lock()
        defer { lock.unlock() }
        guard remainingNanosecondsLocked() > 0, let activation else { return nil }
        return Authorization(journeyID: journeyID, activationID: activation.id, session: self)
    }

    private func isValid(_ identifier: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return remainingNanosecondsLocked() > 0 && activation?.id == identifier
    }

    /// Called under the lock. Expiry is irrevocable, even with a bad test clock.
    private func remainingNanosecondsLocked() -> UInt64 {
        guard let activation else { return 0 }
        let now = clock()
        guard now >= activation.startedAt,
              now - activation.startedAt < Self.lifetimeNanoseconds else {
            self.activation = nil
            return 0
        }
        return Self.lifetimeNanoseconds - (now - activation.startedAt)
    }
}
