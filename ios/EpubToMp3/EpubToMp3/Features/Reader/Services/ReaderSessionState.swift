import Foundation

enum ReaderSessionState {
    static let currentlyReadingBookIDKey = "currentlyReadingBookID"

    static func setCurrentlyReading(bookID: String?, defaults: UserDefaults = .standard) {
        if let bookID, !bookID.isEmpty {
            defaults.set(bookID, forKey: currentlyReadingBookIDKey)
        } else {
            defaults.removeObject(forKey: currentlyReadingBookIDKey)
        }
    }
}
