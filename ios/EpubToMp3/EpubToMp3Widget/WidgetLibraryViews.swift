import WidgetKit
import SwiftUI

// MARK: Library — Book Cell

private struct LibraryBookCell: View {
    let book: LibraryEntry.LibraryBookItem

    var body: some View {
        Link(destination: WidgetDeepLinks.open(bookId: book.id)) {
            VStack(spacing: 4) {
                boundedWidgetCover(from: book.coverData, inset: 4, placeholderSize: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(book.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text(L10n.string("widget.libraryEmpty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.string("widget.importEpubToStart"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.string("nav.library"), systemImage: "books.vertical")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)

                HStack(spacing: 12) {
                    ForEach(entry.books.prefix(3)) { book in
                        LibraryBookCell(book: book)
                    }
                }
            }
            .padding(10)
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
                Text(L10n.string("widget.libraryEmpty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(L10n.string("widget.importEpubToStart"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.string("nav.library"), systemImage: "books.vertical")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)

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
            }
            .padding(10)
        }
    }
}

// MARK: Library — Widget

struct LibraryWidget: Widget {
    let kind = "LibraryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LibraryProvider()) { entry in
            LibraryEntryView(entry: entry)
                .homeWidgetBackground()
                .widgetURL(URL(string: "epubtomp3://library")!)
        }
        .configurationDisplayName("nav.library")
        .description("widget.libraryDescription")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
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
