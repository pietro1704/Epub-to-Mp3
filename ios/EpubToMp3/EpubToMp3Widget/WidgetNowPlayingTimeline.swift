import WidgetKit
import Foundation

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let title: String
    let author: String?
    let chapterName: String?
    let chapterIndex: Int?
    let progress: Double
    let isPlaying: Bool
    let coverData: Data?
    let bookId: String?
    let chapterRemainingSeconds: Double
    let bookRemainingSeconds: Double
    let totalChapters: Int?

    static var placeholder: NowPlayingEntry {
        NowPlayingEntry(
            date: Date(),
            title: "Foundation",
            author: "Isaac Asimov",
            chapterName: "The Psychohistorians",
            chapterIndex: 2,
            progress: 0.35,
            isPlaying: true,
            coverData: nil,
            bookId: nil,
            chapterRemainingSeconds: 42 * 60,
            bookRemainingSeconds: 9 * 3600,
            totalChapters: 18
        )
    }

    static var empty: NowPlayingEntry {
        NowPlayingEntry(
            date: Date(),
            title: "",
            author: nil,
            chapterName: nil,
            chapterIndex: nil,
            progress: 0,
            isPlaying: false,
            coverData: nil,
            bookId: nil,
            chapterRemainingSeconds: 0,
            bookRemainingSeconds: 0,
            totalChapters: nil
        )
    }
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(context.isPreview ? .placeholder : loadNowPlaying())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = loadNowPlaying()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    func loadNowPlaying(defaults: UserDefaults? = WidgetSharedLibrary.defaults()) -> NowPlayingEntry {
        guard let defaults else { return .empty }
        let books = WidgetSharedLibrary.loadBooks(defaults: defaults)
        guard let nowPlayingId = defaults.string(forKey: WidgetSharedLibrary.nowPlayingKey),
              let book = books.first(where: { $0.id == nowPlayingId }) else {
            return .empty
        }
        let chapterName = defaults.string(forKey: WidgetSharedLibrary.nowPlayingChapterNameKey)
        let progress = defaults.double(forKey: WidgetSharedLibrary.nowPlayingProgressKey)
        let isPlaying = defaults.bool(forKey: WidgetSharedLibrary.nowPlayingIsPlayingKey)
        let chapterRemaining = defaults.double(forKey: WidgetSharedLibrary.nowPlayingChapterRemainingKey)
        let bookRemaining = defaults.double(forKey: WidgetSharedLibrary.nowPlayingBookRemainingKey)
        let totalChapters = defaults.object(forKey: WidgetSharedLibrary.nowPlayingTotalChaptersKey) as? Int
        // Only THIS book's cover survives into the entry. `WidgetSharedLibrary.loadBooks(defaults: defaults)`
        // has already decoded the whole array, but keeping a single
        // reference lets the rest (and their cover blobs) be released
        // before the SwiftUI render pass in the memory-capped
        // (~30 MB) widget process.
        let cover = WidgetCoverThumbnail.make(book.coverPNG)

        return NowPlayingEntry(
            date: Date(),
            title: book.title,
            author: defaults.string(forKey: WidgetSharedLibrary.nowPlayingAuthorKey) ?? book.author,
            chapterName: chapterName,
            chapterIndex: book.lastChapterIndex,
            progress: progress,
            isPlaying: isPlaying,
            coverData: cover,
            bookId: book.id,
            chapterRemainingSeconds: chapterRemaining,
            bookRemainingSeconds: bookRemaining,
            totalChapters: totalChapters
        )
    }
}
