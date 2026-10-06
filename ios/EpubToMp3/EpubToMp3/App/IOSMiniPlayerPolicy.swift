import Foundation

enum IOSMiniPlayerPolicy {
    /// The mini player is the only "listen" affordance while reading (no
    /// separate "Ouvir" button) — it must be visible the moment a book is
    /// open, even before any conversion/playback has started, mirroring
    /// the macOS reader's "barra inferior aparece imediatamente ao abrir
    /// o livro". It's also shown outside the reader while something is
    /// actively playing in the background (browsing the Library tab).
    static func shouldShow(
        currentBookID: String?,
        currentlyReadingBookID: String?,
        availableBookIDs: Set<String>
    ) -> Bool {
        func isValid(_ id: String?) -> Bool {
            guard let id, !id.isEmpty else { return false }
            return availableBookIDs.contains(id)
        }
        return isValid(currentlyReadingBookID) || isValid(currentBookID)
    }
}
