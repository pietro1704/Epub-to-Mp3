import WidgetKit
import SwiftUI
import AppIntents

// MARK: Now Playing — Small

private struct NowPlayingSmallView: View {
    let entry: NowPlayingEntry

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                coverImage(from: entry.coverData)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .padding(8)
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
                        if let chapter = entry.chapterName, !chapter.isEmpty {
                            Text(
                                entry.totalChapters.flatMap { total in
                                    entry.chapterIndex.map { "\(chapter) · Cap. \($0 + 1) de \(total)" }
                                } ?? chapter
                            )
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                        Text("\(formatWidgetTime(entry.chapterRemainingSeconds)) restantes · livro \(formatWidgetTime(entry.bookRemainingSeconds))")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(10)
            }
        }
    }
}

// MARK: Now Playing — Medium

@available(iOS 17.0, *)
private struct NowPlayingMediumView: View {
    let entry: NowPlayingEntry

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                coverImage(from: entry.coverData)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .padding(8)
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

                Text("\(formatWidgetTime(entry.chapterRemainingSeconds)) restantes · livro \(formatWidgetTime(entry.bookRemainingSeconds))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

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

@available(iOS 17.0, *)
struct NowPlayingWidget: Widget {
    let kind = "NowPlayingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetDeepLinks.player(bookId: entry.bookId))
        }
        .configurationDisplayName("Now Playing")
        .description("See what audiobook is playing and control playback.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@available(iOS 17.0, *)
struct NowPlayingEntryView: View {
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
