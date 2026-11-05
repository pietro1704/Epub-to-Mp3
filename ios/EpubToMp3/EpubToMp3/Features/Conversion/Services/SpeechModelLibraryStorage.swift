import Foundation

extension SpeechModelLibraryClient {
    nonisolated static func volumeCapacity(_ root: URL) throws -> UInt64 {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 else {
            throw SpeechModelInstallationError.transport("Available storage could not be determined")
        }
        return UInt64(capacity)
    }
}
