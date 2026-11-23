import Foundation

enum ReaderSessionState {
    static let currentlyReadingBookIDKey = ReaderLocation.Key.readingBook

    static func setCurrentlyReading(bookID: String?, defaults: UserDefaults = .standard) {
        ReaderLocation(defaults: defaults).setReadingBook(bookID)
    }
}
