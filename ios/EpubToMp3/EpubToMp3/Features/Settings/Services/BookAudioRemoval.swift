import Foundation

/// Owns one confirmed removal attempt per literal book identity.
@MainActor
final class BookAudioRemoval {
    private var activeBookIDs: Set<String> = []

    func remove(bookID: String, using operation: (String) async throws -> Void) async throws -> Bool {
        try Task.checkCancellation()
        guard activeBookIDs.insert(bookID).inserted else { return false }
        defer { activeBookIDs.remove(bookID) }
        try await operation(bookID)
        return true
    }
}
