import Foundation

enum ReaderSessionState {
    static let currentlyReadingBookIDKey = "currentlyReadingBookID"

    static func setCurrentlyReading(bookID: String?, defaults: UserDefaults = .standard) {
        if let bookID, !bookID.isEmpty {
            defaults.set(bookID, forKey: currentlyReadingBookIDKey)
        } else {
            guard let currentValue = defaults.string(forKey: currentlyReadingBookIDKey) else { return }
            guard !currentValue.isEmpty else { return }
            defaults.removeObject(forKey: currentlyReadingBookIDKey)
            if defaults.string(forKey: currentlyReadingBookIDKey) != nil {
                defaults.set("", forKey: currentlyReadingBookIDKey)
            }
        }
    }
}
