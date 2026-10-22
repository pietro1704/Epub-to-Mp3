import Foundation

struct WidgetBook: Codable {
    let id: String
    var title: String
    var author: String?
    var lastOpenedAt: Date?
    var lastChapterIndex: Int?
    var coverPNG: Data?

    enum CodingKeys: String, CodingKey {
        case id, title, author, lastOpenedAt, lastChapterIndex, coverPNG
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(String.self, forKey: .id)
        title          = try c.decode(String.self, forKey: .title)
        author         = try c.decodeIfPresent(String.self, forKey: .author)
        lastOpenedAt   = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        lastChapterIndex = try c.decodeIfPresent(Int.self, forKey: .lastChapterIndex)
        coverPNG       = try c.decodeIfPresent(Data.self, forKey: .coverPNG)
    }
}

enum WidgetSharedLibrary {
    static let appGroupID = "group.com.pietrocode.epubtomp3"
    static let libraryKey = "library.books.v1"
    static let nowPlayingKey = "currentlyPlayingBookId"
    static let nowPlayingChapterNameKey = "widget.nowPlayingChapterName"
    static let nowPlayingAuthorKey = "widget.nowPlayingAuthor"
    static let nowPlayingProgressKey = "widget.nowPlayingProgress"
    static let nowPlayingIsPlayingKey = "widget.nowPlayingIsPlaying"
    static let nowPlayingChapterRemainingKey = "widget.nowPlayingChapterRemainingSeconds"
    static let nowPlayingBookRemainingKey = "widget.nowPlayingBookRemainingSeconds"
    static let nowPlayingTotalChaptersKey = "widget.nowPlayingTotalChapters"
    static let lastReadBookIdKey = "widget.lastReadBookId"
    static let lastReadChapterIndexKey = "widget.lastReadChapterIndex"
    static let lastReadTotalChaptersKey = "widget.lastReadTotalChapters"
    static let lastReadChapterLabelKey = "widget.lastReadChapterLabel"

    static func defaults() -> UserDefaults? { UserDefaults(suiteName: appGroupID) }

    static func loadBooks(defaults: UserDefaults?) -> [WidgetBook] {
        guard
            let defaults,
            let data = defaults.data(forKey: libraryKey),
            let books = try? JSONDecoder().decode([WidgetBook].self, from: data)
        else { return [] }
        return books
    }

}
