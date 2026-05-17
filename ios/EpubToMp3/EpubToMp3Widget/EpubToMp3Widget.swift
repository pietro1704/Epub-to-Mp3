import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Shared constants

private let appGroupID = "group.com.pietrocode.epubtomp3"
private let libraryKey = "library.books.v1"
private let nowPlayingKey = "currentlyPlayingBookId"
private let nowPlayingChapterNameKey = "widget.nowPlayingChapterName"
private let nowPlayingProgressKey = "widget.nowPlayingProgress"
private let nowPlayingIsPlayingKey = "widget.nowPlayingIsPlaying"
private let lastReadBookIdKey = "widget.lastReadBookId"
private let lastReadChapterIndexKey = "widget.lastReadChapterIndex"
private let lastReadTotalChaptersKey = "widget.lastReadTotalChapters"

// MARK: - Minimal BookEntity copy (widget runs in a separate process)

private struct WidgetBook: Codable {
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

// MARK: - Shared helpers

private func loadBooks() -> [WidgetBook] {
    guard
        let defaults = UserDefaults(suiteName: appGroupID),
        let data = defaults.data(forKey: libraryKey),
        let books = try? JSONDecoder().decode([WidgetBook].self, from: data)
    else { return [] }
    return books
}

private func sharedDefaults() -> UserDefaults? {
    UserDefaults(suiteName: appGroupID)
}

// MARK: - Cross-platform UIImage/NSImage shim

#if canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
extension Image {
    init(platformImage img: UIImage) { self.init(uiImage: img) }
}
#elseif canImport(AppKit)
import AppKit
private typealias PlatformImage = NSImage
extension Image {
    init(platformImage img: NSImage) { self.init(nsImage: img) }
}
#endif

// MARK: - Deep-link URL helpers

private func deepLinkOpen(bookId: String?) -> URL {
    guard let id = bookId else { return URL(string: "epubtomp3://library")! }
    return URL(string: "epubtomp3://open?bookId=\(id)")!
}

private func deepLinkPlayer(bookId: String?) -> URL {
    guard let id = bookId else { return URL(string: "epubtomp3://library")! }
    return URL(string: "epubtomp3://player?bookId=\(id)")!
}

// MARK: - Cover image helper

@ViewBuilder
private func coverImage(from data: Data?, size: CGFloat = 28) -> some View {
    if let data, let img = PlatformImage(data: data) {
        Image(platformImage: img)
            .resizable()
            .scaledToFill()
    } else {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.15), Color(white: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: size, weight: .light))
                    .foregroundStyle(.white.opacity(0.25))
            }
    }
}

// ============================================================================
// MARK: - 1. Now Playing Widget
// ============================================================================

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
            bookId: nil
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
            bookId: nil
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

    private func loadNowPlaying() -> NowPlayingEntry {
        guard let defaults = sharedDefaults() else { return .empty }
        let books = loadBooks()
        guard let nowPlayingId = defaults.string(forKey: nowPlayingKey),
              let book = books.first(where: { $0.id == nowPlayingId }) else {
            return .empty
        }
        let chapterName = defaults.string(forKey: nowPlayingChapterNameKey)
        let progress = defaults.double(forKey: nowPlayingProgressKey)
        let isPlaying = defaults.bool(forKey: nowPlayingIsPlayingKey)

        return NowPlayingEntry(
            date: Date(),
            title: book.title,
            author: book.author,
            chapterName: chapterName,
            chapterIndex: book.lastChapterIndex,
            progress: progress,
            isPlaying: isPlaying,
            coverData: book.coverPNG,
            bookId: book.id
        )
    }
}

// MARK: Now Playing — Small

private struct NowPlayingSmallView: View {
    let entry: NowPlayingEntry

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                coverImage(from: entry.coverData)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.8)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 2) {
                    if entry.title.isEmpty {
                        Text("No audiobook playing")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.7))
                            Text("Now Playing")
                                .font(.system(size: 9, weight: .medium))
                                .textCase(.uppercase)
                                .foregroundStyle(.white.opacity(0.7))
                        }

                        Text(entry.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                }
                .padding(10)
            }
        }
    }
}

// MARK: Now Playing — Medium

private struct NowPlayingMediumView: View {
    let entry: NowPlayingEntry

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                coverImage(from: entry.coverData)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Label(
                    entry.isPlaying ? "Now Playing" : "Paused",
                    systemImage: entry.isPlaying ? "waveform" : "pause.fill"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer(minLength: 0)

                if entry.title.isEmpty {
                    Text("Open a book to start listening")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(entry.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    if let author = entry.author {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let chapterName = entry.chapterName, !chapterName.isEmpty {
                        Text(chapterName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.top, 1)
                    } else if let idx = entry.chapterIndex {
                        Text("Chapter \(idx + 1)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: 0)

                // Progress bar + playback controls
                if !entry.title.isEmpty {
                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.quaternary)
                                .frame(height: 3)
                            Capsule()
                                .fill(.primary)
                                .frame(width: geo.size.width * max(0, min(1, entry.progress)), height: 3)
                        }
                    }
                    .frame(height: 3)

                    HStack(spacing: 16) {
                        Button(intent: TogglePlayPauseIntent()) {
                            Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)

                        Button(intent: SkipForward30Intent()) {
                            Image(systemName: "goforward.30")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Now Playing — Widget

struct NowPlayingWidget: Widget {
    let kind = "NowPlayingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(deepLinkPlayer(bookId: entry.bookId))
        }
        .configurationDisplayName("Now Playing")
        .description("See what audiobook is playing and control playback.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

private struct NowPlayingEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        switch family {
        case .systemSmall:
            NowPlayingSmallView(entry: entry)
        default:
            NowPlayingMediumView(entry: entry)
        }
    }
}

// MARK: - Widget Intents (trampoline via App Group UserDefaults)

/// Play/Pause: writes a flag the main app reads on foreground.
struct TogglePlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play / Pause"
    static let description = IntentDescription("Toggles audio playback.")

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: appGroupID)?
            .set(true, forKey: "widget.intent.togglePlayPause")
        return .result()
    }
}

/// Skip forward 30 seconds.
struct SkipForward30Intent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward 30s"
    static let description = IntentDescription("Skips forward 30 seconds in the audiobook.")

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: appGroupID)?
            .set(true, forKey: "widget.intent.skipForward30")
        return .result()
    }
}

// ============================================================================
// MARK: - 2. Continue Reading Widget
// ============================================================================

struct ContinueReadingEntry: TimelineEntry {
    let date: Date
    let title: String
    let author: String?
    let chapterIndex: Int?
    let totalChapters: Int?
    let coverData: Data?
    let bookId: String?

    var progressPercent: Int? {
        guard let total = totalChapters, total > 0,
              let current = chapterIndex else { return nil }
        return Int(Double(current + 1) / Double(total) * 100)
    }

    var chapterLabel: String? {
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

    private func loadContinueReading() -> ContinueReadingEntry {
        guard let defaults = sharedDefaults() else { return .empty }
        let books = loadBooks()

        // Prefer the explicitly-set last-read book, then fall back to
        // most-recently-opened book in the library.
        let targetId: String? =
            defaults.string(forKey: lastReadBookIdKey)
            ?? books
                .filter { $0.lastOpenedAt != nil }
                .max(by: { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) })
                .map(\.id)

        guard let bookId = targetId,
              let book = books.first(where: { $0.id == bookId }) else {
            return .empty
        }

        let chapterIndex = defaults.object(forKey: lastReadChapterIndexKey) as? Int
            ?? book.lastChapterIndex
        let totalChapters = defaults.object(forKey: lastReadTotalChaptersKey) as? Int

        return ContinueReadingEntry(
            date: Date(),
            title: book.title,
            author: book.author,
            chapterIndex: chapterIndex,
            totalChapters: totalChapters,
            coverData: book.coverPNG,
            bookId: book.id
        )
    }
}

// MARK: Continue Reading — Small

private struct ContinueReadingSmallView: View {
    let entry: ContinueReadingEntry

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                coverImage(from: entry.coverData)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.8)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 2) {
                    if entry.title.isEmpty {
                        Text("No book in progress")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Text("Continue")
                            .font(.system(size: 9, weight: .medium))
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.7))

                        Text(entry.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)

                        if let pct = entry.progressPercent {
                            Text("\(pct)%")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .padding(10)
            }
        }
    }
}

// MARK: Continue Reading — Medium

private struct ContinueReadingMediumView: View {
    let entry: ContinueReadingEntry

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                coverImage(from: entry.coverData)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Label("Continue Reading", systemImage: "book.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if entry.title.isEmpty {
                    Text("Open a book to start reading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(entry.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    if let author = entry.author {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let label = entry.chapterLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: 0)

                // Progress bar
                if let pct = entry.progressPercent {
                    VStack(alignment: .leading, spacing: 2) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.quaternary)
                                    .frame(height: 4)
                                Capsule()
                                    .fill(.tint)
                                    .frame(width: geo.size.width * CGFloat(pct) / 100, height: 4)
                            }
                        }
                        .frame(height: 4)

                        Text("\(pct)% complete")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Continue Reading — Widget

struct ContinueReadingWidget: Widget {
    let kind = "ContinueReadingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContinueReadingProvider()) { entry in
            ContinueReadingEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(deepLinkOpen(bookId: entry.bookId))
        }
        .configurationDisplayName("Continue Reading")
        .description("Jump back into the book you were reading.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

private struct ContinueReadingEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueReadingEntry

    var body: some View {
        switch family {
        case .systemSmall:
            ContinueReadingSmallView(entry: entry)
        default:
            ContinueReadingMediumView(entry: entry)
        }
    }
}

// ============================================================================
// MARK: - 3. Library Widget
// ============================================================================

struct LibraryEntry: TimelineEntry {
    let date: Date
    let books: [LibraryBookItem]

    struct LibraryBookItem: Identifiable {
        let id: String
        let title: String
        let author: String?
        let coverData: Data?
    }

    static var placeholder: LibraryEntry {
        LibraryEntry(date: Date(), books: [
            LibraryBookItem(id: "1", title: "Foundation", author: "Isaac Asimov", coverData: nil),
            LibraryBookItem(id: "2", title: "Metro 2033", author: "Dmitry Glukhovsky", coverData: nil),
            LibraryBookItem(id: "3", title: "O Hobbit", author: "J.R.R. Tolkien", coverData: nil),
            LibraryBookItem(id: "4", title: "Dune", author: "Frank Herbert", coverData: nil),
            LibraryBookItem(id: "5", title: "Neuromancer", author: "William Gibson", coverData: nil),
            LibraryBookItem(id: "6", title: "1984", author: "George Orwell", coverData: nil),
        ])
    }

    static var empty: LibraryEntry {
        LibraryEntry(date: Date(), books: [])
    }
}

struct LibraryProvider: TimelineProvider {
    func placeholder(in context: Context) -> LibraryEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (LibraryEntry) -> Void) {
        completion(context.isPreview ? .placeholder : loadLibrary())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LibraryEntry>) -> Void) {
        let entry = loadLibrary()
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadLibrary() -> LibraryEntry {
        let books = loadBooks()
        guard !books.isEmpty else { return .empty }

        // Sort by most recently opened, then by most recently added.
        let sorted = books.sorted { a, b in
            (a.lastOpenedAt ?? .distantPast) > (b.lastOpenedAt ?? .distantPast)
        }

        let items = sorted.prefix(6).map { book in
            LibraryEntry.LibraryBookItem(
                id: book.id,
                title: book.title,
                author: book.author,
                coverData: book.coverPNG
            )
        }

        return LibraryEntry(date: Date(), books: items)
    }
}

// MARK: Library — Book Cell

private struct LibraryBookCell: View {
    let book: LibraryEntry.LibraryBookItem

    var body: some View {
        Link(destination: deepLinkOpen(bookId: book.id)) {
            VStack(spacing: 4) {
                coverImage(from: book.coverData, size: 20)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(0.7, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(book.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

// MARK: Library — Medium (2-3 books)

private struct LibraryMediumView: View {
    let entry: LibraryEntry

    var body: some View {
        if entry.books.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "books.vertical")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Your library is empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Import an EPUB to get started")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Library", systemImage: "books.vertical")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    ForEach(entry.books.prefix(3)) { book in
                        LibraryBookCell(book: book)
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: Library — Large (4-6 books grid)

private struct LibraryLargeView: View {
    let entry: LibraryEntry

    private var rows: [[LibraryEntry.LibraryBookItem]] {
        let items = Array(entry.books.prefix(6))
        guard !items.isEmpty else { return [] }
        // 2 rows: first row up to 3, second row the rest
        let firstRow = Array(items.prefix(3))
        let secondRow = items.count > 3 ? Array(items.dropFirst(3)) : []
        var result = [firstRow]
        if !secondRow.isEmpty { result.append(secondRow) }
        return result
    }

    var body: some View {
        if entry.books.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Your library is empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Import an EPUB to get started")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Library", systemImage: "books.vertical")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 12) {
                        ForEach(row) { book in
                            LibraryBookCell(book: book)
                        }
                        // Pad remaining space if row has fewer than 3
                        if row.count < 3 {
                            ForEach(0..<(3 - row.count), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}

// MARK: Library — Widget

struct LibraryWidget: Widget {
    let kind = "LibraryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LibraryProvider()) { entry in
            LibraryEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "epubtomp3://library")!)
        }
        .configurationDisplayName("Library")
        .description("Quick access to your recent audiobooks.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct LibraryEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LibraryEntry

    var body: some View {
        switch family {
        case .systemLarge:
            LibraryLargeView(entry: entry)
        default:
            LibraryMediumView(entry: entry)
        }
    }
}

// ============================================================================
// MARK: - Legacy compatibility: keep the old EpubToMp3Widget kind alive
// ============================================================================

/// Backwards-compatible widget using the original "EpubToMp3Widget" kind
/// string. If a user had the old widget on their home screen, this ensures
/// it keeps working after the update. Identical to `NowPlayingWidget` in
/// behaviour — the only difference is the `kind` identifier.
struct EpubToMp3Widget: Widget {
    let kind = "EpubToMp3Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(deepLinkPlayer(bookId: entry.bookId))
        }
        .configurationDisplayName("Now Playing")
        .description("Control playback or jump back into your audiobook.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// ============================================================================
// MARK: - Previews
// ============================================================================

#if os(iOS)
// Now Playing
#Preview("Now Playing — small", as: .systemSmall) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry.placeholder
}

#Preview("Now Playing — medium", as: .systemMedium) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry.placeholder
}

#Preview("Now Playing — empty", as: .systemSmall) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry.empty
}

// Continue Reading
#Preview("Continue Reading — small", as: .systemSmall) {
    ContinueReadingWidget()
} timeline: {
    ContinueReadingEntry.placeholder
}

#Preview("Continue Reading — medium", as: .systemMedium) {
    ContinueReadingWidget()
} timeline: {
    ContinueReadingEntry.placeholder
}

#Preview("Continue Reading — empty", as: .systemSmall) {
    ContinueReadingWidget()
} timeline: {
    ContinueReadingEntry.empty
}

// Library
#Preview("Library — medium", as: .systemMedium) {
    LibraryWidget()
} timeline: {
    LibraryEntry.placeholder
}

#Preview("Library — large", as: .systemLarge) {
    LibraryWidget()
} timeline: {
    LibraryEntry.placeholder
}

#Preview("Library — empty", as: .systemMedium) {
    LibraryWidget()
} timeline: {
    LibraryEntry.empty
}
#endif
