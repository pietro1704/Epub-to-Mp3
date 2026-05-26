import WidgetKit
import SwiftUI

// MARK: - Lock-screen / StandBy widgets (iOS 16+)
// Families: .accessoryCircular, .accessoryRectangular, .accessoryInline
// HIG: glanceable, no scroll, no heavy decode — cover art only from pre-cached PNG.

private let appGroupID = "group.com.pietrocode.epubtomp3"
private let nowPlayingKey = "currentlyPlayingBookId"
private let nowPlayingChapterNameKey = "widget.nowPlayingChapterName"
private let nowPlayingProgressKey = "widget.nowPlayingProgress"
private let nowPlayingIsPlayingKey = "widget.nowPlayingIsPlaying"
private let libraryKey = "library.books.v1"

// MARK: - Shared lock-screen entry

struct LockScreenEntry: TimelineEntry {
    let date: Date
    let title: String
    let chapterName: String?
    let progress: Double    // 0.0–1.0
    let isPlaying: Bool
    let bookId: String?

    static var placeholder: LockScreenEntry {
        LockScreenEntry(
            date: Date(),
            title: "Foundation",
            chapterName: "The Psychohistorians",
            progress: 0.35,
            isPlaying: true,
            bookId: nil
        )
    }

    static var empty: LockScreenEntry {
        LockScreenEntry(
            date: Date(),
            title: "",
            chapterName: nil,
            progress: 0,
            isPlaying: false,
            bookId: nil
        )
    }
}

// MARK: - Provider

struct LockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockScreenEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (LockScreenEntry) -> Void) {
        completion(context.isPreview ? .placeholder : load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenEntry>) -> Void) {
        let entry = load()
        // Refresh 30 min ahead; rely on reloadTimelines from main app for real events.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> LockScreenEntry {
        guard
            let defaults = UserDefaults(suiteName: appGroupID),
            let bookId = defaults.string(forKey: nowPlayingKey),
            let data = defaults.data(forKey: libraryKey),
            let books = try? JSONDecoder().decode([_LockWidgetBook].self, from: data),
            let book = books.first(where: { $0.id == bookId })
        else { return .empty }

        return LockScreenEntry(
            date: Date(),
            title: book.title,
            chapterName: defaults.string(forKey: nowPlayingChapterNameKey),
            progress: defaults.double(forKey: nowPlayingProgressKey),
            isPlaying: defaults.bool(forKey: nowPlayingIsPlayingKey),
            bookId: bookId
        )
    }
}

// Minimal book shape — only what lock-screen widgets need.
private struct _LockWidgetBook: Codable {
    let id: String
    let title: String
}

// MARK: - Deep-link helpers (local)

private func deepLinkPlayer(bookId: String?) -> URL {
    guard let id = bookId else { return URL(string: "epubtomp3://library")! }
    return URL(string: "epubtomp3://player?bookId=\(id)")!
}

// MARK: - Accessory Circular — progress ring

private struct CircularView: View {
    let entry: LockScreenEntry

    var body: some View {
        ZStack {
            // Gauge-style progress ring
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, entry.progress))))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: entry.isPlaying ? "waveform" : "headphones")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(4)
    }
}

// MARK: - Accessory Rectangular — title + chapter

private struct RectangularView: View {
    let entry: LockScreenEntry

    var body: some View {
        if entry.title.isEmpty {
            Label("Nothing playing", systemImage: "headphones")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if let chapter = entry.chapterName, !chapter.isEmpty {
                    Text(chapter)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                // Thin progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 2)
                        Capsule().fill(.primary)
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, entry.progress))), height: 2)
                    }
                }
                .frame(height: 2)
            }
        }
    }
}

// MARK: - Accessory Inline — "Playing: <title>"

private struct InlineView: View {
    let entry: LockScreenEntry

    var body: some View {
        if entry.title.isEmpty {
            Label("No audiobook", systemImage: "headphones")
        } else {
            Label(entry.title, systemImage: entry.isPlaying ? "waveform" : "pause")
                .lineLimit(1)
        }
    }
}

// MARK: - NowPlayingLockScreenWidget

@available(iOS 16.1, *)
struct NowPlayingLockScreenWidget: Widget {
    let kind = "NowPlayingLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LockScreenProvider()) { entry in
            NowPlayingLockScreenView(entry: entry)
                .widgetURL(deepLinkPlayer(bookId: entry.bookId))
        }
        .configurationDisplayName("Now Playing")
        .description("Glanceable now-playing info on your lock screen.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

private struct NowPlayingLockScreenView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LockScreenEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularView(entry: entry)
        case .accessoryRectangular:
            RectangularView(entry: entry)
        case .accessoryInline:
            InlineView(entry: entry)
        default:
            EmptyView()
        }
    }
}

// MARK: - Previews

#if os(iOS)
@available(iOS 17.0, *)
#Preview("Lock Circular", as: .accessoryCircular) {
    NowPlayingLockScreenWidget()
} timeline: {
    LockScreenEntry.placeholder
    LockScreenEntry.empty
}

@available(iOS 17.0, *)
#Preview("Lock Rectangular", as: .accessoryRectangular) {
    NowPlayingLockScreenWidget()
} timeline: {
    LockScreenEntry.placeholder
    LockScreenEntry.empty
}

@available(iOS 17.0, *)
#Preview("Lock Inline", as: .accessoryInline) {
    NowPlayingLockScreenWidget()
} timeline: {
    LockScreenEntry.placeholder
    LockScreenEntry.empty
}
#endif
