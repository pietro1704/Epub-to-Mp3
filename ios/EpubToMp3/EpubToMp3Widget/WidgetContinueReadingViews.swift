import WidgetKit
import SwiftUI
import AppIntents

// MARK: Continue Reading — Small

private struct ContinueReadingSmallView: View {
    let entry: ContinueReadingEntry

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
                        if entry.chapterRemainingSeconds > 0 || entry.bookRemainingSeconds > 0 {
                            Text("\(formatWidgetTime(entry.chapterRemainingSeconds)) restantes · livro \(formatWidgetTime(entry.bookRemainingSeconds))")
                                .font(.system(size: 9, design: .rounded))
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
                    .padding(8)
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
                        if entry.chapterRemainingSeconds > 0 || entry.bookRemainingSeconds > 0 {
                            Text("\(formatWidgetTime(entry.chapterRemainingSeconds)) restantes · livro \(formatWidgetTime(entry.bookRemainingSeconds))")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
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

@available(iOS 17.0, *)
struct ContinueReadingWidget: Widget {
    let kind = "ContinueReadingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContinueReadingProvider()) { entry in
            ContinueReadingEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetDeepLinks.open(bookId: entry.bookId))
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
