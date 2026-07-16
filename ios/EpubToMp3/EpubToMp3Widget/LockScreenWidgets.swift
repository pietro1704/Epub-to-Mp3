import WidgetKit
import SwiftUI
import ImageIO
import UIKit

// MARK: - Lock-screen / StandBy widgets (iOS 16+)
// Families: .accessoryCircular, .accessoryRectangular, .accessoryInline
// HIG: glanceable, no scroll, no heavy decode — cover art only from pre-cached PNG.

private let appGroupID = "group.com.pietrocode.epubtomp3"
private let nowPlayingKey = "currentlyPlayingBookId"
private let nowPlayingChapterNameKey = "widget.nowPlayingChapterName"
private let nowPlayingProgressKey = "widget.nowPlayingProgress"
private let nowPlayingIsPlayingKey = "widget.nowPlayingIsPlaying"
private let nowPlayingChapterRemainingKey = "widget.nowPlayingChapterRemainingSeconds"
private let nowPlayingBookRemainingKey = "widget.nowPlayingBookRemainingSeconds"
private let nowPlayingTotalChaptersKey = "widget.nowPlayingTotalChapters"
private let libraryKey = "library.books.v1"

// MARK: - Shared lock-screen entry

struct LockScreenEntry: TimelineEntry {
    let date: Date
    let title: String
    let chapterName: String?
    let progress: Double    // 0.0–1.0
    let isPlaying: Bool
    let bookId: String?
    let coverData: Data?
    let chapterRemainingSeconds: Double
    let bookRemainingSeconds: Double
    let totalChapters: Int?

    static var placeholder: LockScreenEntry {
        LockScreenEntry(
            date: Date(),
            title: "Foundation",
            chapterName: "The Psychohistorians",
            progress: 0.35,
            isPlaying: true,
            bookId: nil,
            coverData: nil,
            chapterRemainingSeconds: 42 * 60,
            bookRemainingSeconds: 9 * 3600,
            totalChapters: 18
        )
    }

    static var empty: LockScreenEntry {
        LockScreenEntry(
            date: Date(),
            title: "",
            chapterName: nil,
            progress: 0,
            isPlaying: false,
            bookId: nil,
            coverData: nil,
            chapterRemainingSeconds: 0,
            bookRemainingSeconds: 0,
            totalChapters: nil
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
            bookId: bookId,
            coverData: downsampledLockWidgetCover(book.coverPNG),
            chapterRemainingSeconds: defaults.double(forKey: nowPlayingChapterRemainingKey),
            bookRemainingSeconds: defaults.double(forKey: nowPlayingBookRemainingKey),
            totalChapters: defaults.object(forKey: nowPlayingTotalChaptersKey) as? Int
        )
    }
}

// Minimal book shape — only what lock-screen widgets need.
private struct _LockWidgetBook: Codable {
    let id: String
    let title: String
    let coverPNG: Data?
}

private func formatLockWidgetTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

private func downsampledLockWidgetCover(_ data: Data?) -> Data? {
    guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 240,
    ] as CFDictionary
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
          let output = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)
    else { return data }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? output as Data : data
}

@ViewBuilder
private func lockCoverImage(_ data: Data?) -> some View {
    if let data, let image = UIImage(data: data) {
        Image(uiImage: image).resizable().scaledToFill()
    } else {
        Image(systemName: "book.closed.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
    }
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
            lockCoverImage(entry.coverData)
                .clipShape(Circle())
                .opacity(0.35)
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

                Text("\(formatLockWidgetTime(entry.chapterRemainingSeconds)) restantes · livro \(formatLockWidgetTime(entry.bookRemainingSeconds))")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

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
            .padding(.leading, 34)
            .overlay(alignment: .leading) {
                lockCoverImage(entry.coverData)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
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
            Label("\(entry.title) · \(formatLockWidgetTime(entry.chapterRemainingSeconds)) restantes", systemImage: entry.isPlaying ? "waveform" : "pause")
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
        if #available(iOS 17.0, *) {
            content
                .containerBackground(for: .widget) {
                    Color.clear
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
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
