import Foundation

/// The persisted reader/player channel shared by both Apple clients.
/// A missing chapter or ratio has a different meaning from chapter zero or the top of a page.
final class ReaderLocation {
    static let standard = ReaderLocation(defaults: .standard)

    enum Key {
        static let readingBook = "currentlyReadingBookID"
        static let playingBook = "currentlyPlayingBookID"
        static let playingChapter = "currentlyPlayingChapterIndex"
        static let readerChapter = "readerCurrentChapterIndex"
        static let pageRatio = "readerCurrentPageRatio"
        static let sentence = "readerCurrentSentenceId"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var readingBookID: String? {
        guard let bookID = defaults.string(forKey: Key.readingBook), !bookID.isEmpty else { return nil }
        return bookID
    }
    var playingBookID: String? { defaults.string(forKey: Key.playingBook) }
    var playingChapter: Int? {
        get { defaults.object(forKey: Key.playingChapter) as? Int }
        set { defaults.set(newValue, forKey: Key.playingChapter) }
    }
    var readerChapter: Int? {
        get { defaults.object(forKey: Key.readerChapter) as? Int }
        set { defaults.set(newValue, forKey: Key.readerChapter) }
    }
    var pageRatio: Double? {
        get { defaults.object(forKey: Key.pageRatio) as? Double }
        set { defaults.set(newValue, forKey: Key.pageRatio) }
    }
    var sentenceID: String? {
        get { defaults.string(forKey: Key.sentence) }
        set { defaults.set(newValue, forKey: Key.sentence) }
    }

    func setReaderAnchor(chapter: Int, pageRatio: Double) {
        readerChapter = chapter
        self.pageRatio = pageRatio
        sentenceID = nil
    }

    func setReadingBook(_ bookID: String?) {
        if let bookID, !bookID.isEmpty {
            defaults.set(bookID, forKey: Key.readingBook)
        } else if let current = readingBookID, !current.isEmpty {
            defaults.removeObject(forKey: Key.readingBook)
            // Removing a stored value can expose a launch-registered book again.
            if readingBookID != nil { defaults.set("", forKey: Key.readingBook) }
        }
    }

    func bindPlayingBook(_ bookID: String?, chapter: Int) {
        if let bookID, !bookID.isEmpty {
            defaults.set(bookID, forKey: Key.playingBook)
            playingChapter = max(0, chapter)
        } else {
            defaults.removeObject(forKey: Key.playingBook)
            playingChapter = nil
        }
    }
}
