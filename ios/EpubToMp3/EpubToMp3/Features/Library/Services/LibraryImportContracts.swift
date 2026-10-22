import Foundation

extension LibraryStore {
    struct ImportOutcome: Sendable {
        let url: URL
        let book: BookEntity?
        let error: String?
    }

    /// Immutable references to Foundation's thread-safe IO services. Only these
    /// resources cross the serial import worker; the mutable store never does.
    /// Injected subclasses must synchronize any additional mutable test state.
    struct ImportResources: @unchecked Sendable {
        let fileManager: FileManager
        let defaults: UserDefaults?
    }

}
