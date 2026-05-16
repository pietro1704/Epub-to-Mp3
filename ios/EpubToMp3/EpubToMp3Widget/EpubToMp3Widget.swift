import WidgetKit
import SwiftUI

// MARK: - Minimal BookEntity copy (widget runs in a separate process)

private enum BookFileType: String, Codable {
    case epub
    case pdf
}

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

// MARK: - Timeline Entry

struct BookWidgetEntry: TimelineEntry {
    let date: Date
    let title: String
    let author: String?
    let chapterIndex: Int?
    let coverData: Data?
    let bookId: String?

    static var placeholder: BookWidgetEntry {
        BookWidgetEntry(
            date: Date(),
            title: "Foundation",
            author: "Isaac Asimov",
            chapterIndex: 2,
            coverData: nil,
            bookId: nil
        )
    }

    static var empty: BookWidgetEntry {
        BookWidgetEntry(
            date: Date(),
            title: "",
            author: nil,
            chapterIndex: nil,
            coverData: nil,
            bookId: nil
        )
    }
}

// MARK: - Provider

struct BookWidgetProvider: TimelineProvider {
    private let appGroupID = "group.com.pietrocode.epubtomp3"
    private let defaultsKey = "library.books.v1"

    func placeholder(in context: Context) -> BookWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (BookWidgetEntry) -> Void) {
        completion(context.isPreview ? .placeholder : loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BookWidgetEntry>) -> Void) {
        let entry = loadEntry()
        // Refresh every 30 minutes so the widget picks up newly opened books
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> BookWidgetEntry {
        guard
            let defaults = UserDefaults(suiteName: appGroupID),
            let data = defaults.data(forKey: defaultsKey),
            let books = try? JSONDecoder().decode([WidgetBook].self, from: data)
        else {
            return .empty
        }

        // Most recently opened book that has a lastOpenedAt; fall back
        // to the most recently added if none has been opened yet.
        let recent = books
            .filter { $0.lastOpenedAt != nil }
            .max(by: { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) })
            ?? books.last

        guard let book = recent else { return .empty }

        return BookWidgetEntry(
            date: Date(),
            title: book.title,
            author: book.author,
            chapterIndex: book.lastChapterIndex,
            coverData: book.coverPNG,
            bookId: book.id
        )
    }
}

// MARK: - Deep-link URL helper

private func deepLinkURL(bookId: String?) -> URL {
    guard let id = bookId else { return URL(string: "epubtomp3://library")! }
    return URL(string: "epubtomp3://open?bookId=\(id)")!
}

// MARK: - Cover image helper

@ViewBuilder
private func coverImage(from data: Data?) -> some View {
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
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.25))
            }
    }
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

// MARK: - Small widget (systemSmall)

private struct SmallWidgetView: View {
    let entry: BookWidgetEntry

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Full-bleed cover (or gradient placeholder)
                coverImage(from: entry.coverData)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                // Scrim + title
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 2) {
                    if entry.title.isEmpty {
                        Text("No book yet")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
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

// MARK: - Medium widget (systemMedium)

private struct MediumWidgetView: View {
    let entry: BookWidgetEntry

    var body: some View {
        HStack(spacing: 0) {
            // Cover panel — fixed 40% width
            GeometryReader { geo in
                coverImage(from: entry.coverData)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .frame(maxWidth: .infinity)

            // Text panel
            VStack(alignment: .leading, spacing: 6) {
                // "Continue Reading" eyebrow
                Label("Continue Reading", systemImage: "headphones")
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

                    if let idx = entry.chapterIndex {
                        Text("Chapter \(idx + 1)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Widget entry point

struct EpubToMp3Widget: Widget {
    let kind = "EpubToMp3Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BookWidgetProvider()) { entry in
            EpubToMp3WidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(deepLinkURL(bookId: entry.bookId))
        }
        .configurationDisplayName("Continue Reading")
        .description("Tap to jump back into your most recently opened book.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Dispatcher view

private struct EpubToMp3WidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BookWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

// MARK: - Previews

#Preview("Small — book", as: .systemSmall) {
    EpubToMp3Widget()
} timeline: {
    BookWidgetEntry.placeholder
}

#Preview("Medium — book", as: .systemMedium) {
    EpubToMp3Widget()
} timeline: {
    BookWidgetEntry.placeholder
}

#Preview("Small — empty", as: .systemSmall) {
    EpubToMp3Widget()
} timeline: {
    BookWidgetEntry.empty
}
