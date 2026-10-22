import Foundation

enum LibraryImportExecutor {
    private static let importQueue = DispatchQueue(label: "com.epubtomp3.library-import", qos: .userInitiated,
                                                  autoreleaseFrequency: .workItem)
    /// Also used by inbox/Document callers for enumeration and source cleanup.
    static func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            importQueue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    static func performSync<Value>(_ operation: () throws -> Value) rethrows -> Value {
        try importQueue.sync(execute: operation)
    }

}
