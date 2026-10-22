import WidgetKit
import SwiftUI
import AppIntents

// MARK: Library — Book Cell

private struct LibraryBookCell: View {
    let book: LibraryEntry.LibraryBookItem

    var body: some View {
        Link(destination: WidgetDeepLinks.open(bookId: book.id)) {
            VStack(spacing: 4) {
                coverImage(from: book.coverData, size: 20)
                    .frame(maxWidth: .infinity)
                    .padding(4)
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

@available(iOS 17.0, *)
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
