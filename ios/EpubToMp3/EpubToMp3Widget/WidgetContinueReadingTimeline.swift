import WidgetKit
import Foundation

struct ContinueReadingEntry: TimelineEntry {
    let date: Date
    let title: String
    let author: String?
    let chapterIndex: Int?
    let totalChapters: Int?
    let coverData: Data?
    let bookId: String?
    // Pre-localized in the host app (the extension bundles no
    // Localizable.strings); nil only for stale pre-update payloads.
    var localizedChapterLabel: String? = nil
    var chapterRemainingSeconds: Double = 0
    var bookRemainingSeconds: Double = 0

    var progressPercent: Int? {
        guard let total = totalChapters, total > 0,
              let current = chapterIndex else { return nil }
        return Int(Double(current + 1) / Double(total) * 100)
    }

    var chapterLabel: String? {
        if let localizedChapterLabel, !localizedChapterLabel.isEmpty {
            return localizedChapterLabel
        }
        guard let idx = chapterIndex else { return nil }
        if let total = totalChapters, total > 0 {
            return "Chapter \(idx + 1) of \(total)"
        }
        return "Chapter \(idx + 1)"
    }

    static var placeholder: ContinueReadingEntry {
        ContinueReadingEntry(
            date: Date(),
            title: "Foundation",
            author: "Isaac Asimov",
            chapterIndex: 4,
            totalChapters: 18,
            coverData: nil,
            bookId: nil
        )
    }

    static var empty: ContinueReadingEntry {
        ContinueReadingEntry(
            date: Date(),
            title: "",
            author: nil,
            chapterIndex: nil,
            totalChapters: nil,
            coverData: nil,
            bookId: nil
        )
    }
}

struct ContinueReadingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueReadingEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ContinueReadingEntry) -> Void) {
        completion(context.isPreview ? .placeholder : loadContinueReading())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueReadingEntry>) -> Void) {
        let entry = loadContinueReading()
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    func loadContinueReading(defaults: UserDefaults? = WidgetSharedLibrary.defaults()) -> ContinueReadingEntry {
        guard let defaults else { return .empty }
        let books = WidgetSharedLibrary.loadBooks(defaults: defaults)

        // Prefer the explicitly-set last-read book, then fall back to
        // most-recently-opened book in the library.
        let targetId: String? =
            defaults.string(forKey: WidgetSharedLibrary.lastReadBookIdKey)
            ?? books
                .filter { $0.lastOpenedAt != nil }
                .max(by: { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) })
                .map(\.id)

        guard let bookId = targetId,
              let book = books.first(where: { $0.id == bookId }) else {
            return .empty
        }

        let chapterIndex = defaults.object(forKey: WidgetSharedLibrary.lastReadChapterIndexKey) as? Int
            ?? book.lastChapterIndex
        let totalChapters = defaults.object(forKey: WidgetSharedLibrary.lastReadTotalChaptersKey) as? Int
        let isNowPlaying = defaults.string(forKey: WidgetSharedLibrary.nowPlayingKey) == bookId

        return ContinueReadingEntry(
            date: Date(),
            title: book.title,
            author: book.author,
            chapterIndex: chapterIndex,
            totalChapters: totalChapters,
            coverData: book.coverPNG,
            bookId: book.id,
            localizedChapterLabel: defaults.string(forKey: WidgetSharedLibrary.lastReadChapterLabelKey),
            chapterRemainingSeconds: isNowPlaying ? defaults.double(forKey: WidgetSharedLibrary.nowPlayingChapterRemainingKey) : 0,
            bookRemainingSeconds: isNowPlaying ? defaults.double(forKey: WidgetSharedLibrary.nowPlayingBookRemainingKey) : 0
        )
    }
}
