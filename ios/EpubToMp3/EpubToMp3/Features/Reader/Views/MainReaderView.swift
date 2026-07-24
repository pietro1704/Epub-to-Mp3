import Foundation

/// Reader navigation state shared by UIKit/AppKit controllers.
/// The old SwiftUI landing view was replaced by `MainReaderScreenController`.
struct MainReaderView {
    static let currentlyReadingBookIDKey = "currentlyReadingBookID"

    init(onBrowseLibrary: (() -> Void)? = nil) {}

    static func setCurrentlyReading(bookID: String?, defaults: UserDefaults = .standard) {
        if let bookID, !bookID.isEmpty {
            defaults.set(bookID, forKey: currentlyReadingBookIDKey)
        } else {
            defaults.removeObject(forKey: currentlyReadingBookIDKey)
        }
    }
}
