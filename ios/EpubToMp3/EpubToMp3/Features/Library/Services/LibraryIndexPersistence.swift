import Foundation

/// Queue-confined writer. Foundation UserDefaults is thread-safe; mutable error
/// state is accessed only on the serial queue. No LibraryStore reference crosses
/// this boundary, and queued snapshots are immutable Sendable values.
final class LibraryIndexPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.epubtomp3.library-index", qos: .utility,
                                      autoreleaseFrequency: .workItem)
    private let defaults: UserDefaults
    private let key: String
    private let encoder: @Sendable ([BookEntity]) throws -> Data
    private var lastFailure: Error?

    init(defaults: UserDefaults, key: String,
         encoder: @escaping @Sendable ([BookEntity]) throws -> Data) {
        self.defaults = defaults
        self.key = key
        self.encoder = encoder
    }

    func enqueue(_ snapshot: [BookEntity]) {
        queue.async { [self] in
            do {
                let data = try encoder(snapshot)
                defaults.set(data, forKey: key)
                lastFailure = nil
                WidgetDataSync.reloadLibraryWidgets()
            } catch {
                lastFailure = error
                NSLog("Library persistence failed: %@", error.localizedDescription)
            }
        }
    }

    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let lastFailure { continuation.resume(throwing: lastFailure) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func flushSync() throws {
        try queue.sync {
            if let lastFailure { throw lastFailure }
        }
    }
}
