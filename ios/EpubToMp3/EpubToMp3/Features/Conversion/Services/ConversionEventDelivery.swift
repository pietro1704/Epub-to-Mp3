import Foundation

/// Hands one job's callback events from the Rust worker thread to the MainActor.
final class ConversionEventDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Task<Void, Never>?

    /// Callable from any thread. Events run one at a time, in posting order.
    func post(_ work: @escaping @MainActor @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        let previous = last
        last = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Returns once every event posted before this call has been handled.
    func drain() async {
        await pending()?.value
    }

    private func pending() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return last
    }
}
