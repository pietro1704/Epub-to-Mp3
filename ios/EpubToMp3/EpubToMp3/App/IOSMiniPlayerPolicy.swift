import Foundation

enum IOSMiniPlayerPolicy {
    static func shouldShow(
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
