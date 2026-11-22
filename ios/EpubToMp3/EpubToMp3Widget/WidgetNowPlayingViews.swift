import WidgetKit
import SwiftUI
import AppIntents

// MARK: Now Playing — Small

private struct NowPlayingSmallView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: NowPlayingEntry

    var body: some View {
        boundedWidgetCover(from: entry.coverData, inset: 8)
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.8)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    if entry.title.isEmpty {
                        Text(L10n.string("widget.noAudiobookPlaying"))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                    } else {
                        if !dynamicTypeSize.isAccessibilitySize {
                            Label(
                                L10n.string(entry.isPlaying ? "widget.nowPlaying" : "widget.paused"),
                                systemImage: entry.isPlaying ? "waveform" : "pause.fill"
                            )
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        }

                        Text(entry.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .layoutPriority(1)
                        if !dynamicTypeSize.isAccessibilitySize,
                           let chapter = entry.chapterName, !chapter.isEmpty {
                            Text(
                                entry.totalChapters.flatMap { total in
                                    entry.chapterIndex.map { "\(chapter) · \(L10n.string("player.chapterOf", $0 + 1, total))" }
                                } ?? chapter
                            )
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text(L10n.string("widget.remainingTimes", formatWidgetTime(entry.chapterRemainingSeconds), formatWidgetTime(entry.bookRemainingSeconds)))
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
                .padding(10)
            }
    }
}

// MARK: Now Playing — Medium

private struct NowPlayingMediumView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: NowPlayingEntry

    var body: some View {
        HStack(spacing: 0) {
            boundedWidgetCover(from: entry.coverData, inset: 8)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Label(
                    L10n.string(entry.isPlaying ? "widget.nowPlaying" : "widget.paused"),
                    systemImage: entry.isPlaying ? "waveform" : "pause.fill"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if entry.title.isEmpty {
                    Text(L10n.string("widget.openBookToListen"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                } else {
                    Text(entry.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)

                    if dynamicTypeSize <= .large {
                        metadata
                    }

                    Spacer(minLength: 0)
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

                    if #available(iOS 17.0, macOS 14.0, *) {
                        playbackControls
                    }
                }
            }
            .padding(.trailing, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var metadata: some View {
        if let author = entry.author {
            Text(author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        if let chapter = entry.chapterName.flatMap({ $0.isEmpty ? nil : $0 })
            ?? entry.chapterIndex.map({ L10n.string("player.chapter", $0 + 1) }) {
            Text(chapter)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }

        Text(L10n.string("widget.remainingTimes", formatWidgetTime(entry.chapterRemainingSeconds), formatWidgetTime(entry.bookRemainingSeconds)))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    @available(iOS 17.0, macOS 14.0, *)
    private var playbackControls: some View {
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

// MARK: Now Playing — Widget

struct NowPlayingWidget: Widget {
    let kind = "NowPlayingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingEntryView(entry: entry)
                .homeWidgetBackground()
                .widgetURL(WidgetDeepLinks.player(bookId: entry.bookId))
        }
        .configurationDisplayName("widget.nowPlaying")
        .description("widget.playbackDescription")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

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
