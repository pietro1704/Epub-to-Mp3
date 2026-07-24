import Foundation

/// Shared navigation tokens kept independent from any UI framework.
/// UIKit and AppKit controllers own the actual navigation hierarchy.
enum RootTab: Int, Hashable {
    case library
    case settings
    case convert
}

enum RootView {
    static func shouldShowMiniPlayer(
        currentBookID: String?,
        currentlyReadingBookID: String?,
        availableBookIDs: Set<String>
    ) -> Bool {
        guard let currentBookID, !currentBookID.isEmpty else { return false }
        guard availableBookIDs.contains(currentBookID) else { return false }
        guard let currentlyReadingBookID, !currentlyReadingBookID.isEmpty else { return true }
        return currentBookID != currentlyReadingBookID
    }
}
