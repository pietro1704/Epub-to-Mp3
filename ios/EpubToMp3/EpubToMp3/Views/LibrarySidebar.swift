import SwiftUI

/// Compact, sidebar-friendly variant of the library grid. Renders one
/// row per book — cover thumb, title, author, status pill — and binds
/// the selected book id to the caller so the `NavigationSplitView`
/// content column can react.
///
/// Visual contract: the sidebar lives in the leading column of a
/// `NavigationSplitView` on iPad / macOS. Keep it dense (List + small
/// thumbs); the rich poster-style grid stays in `LibraryView` for the
/// compact phone layout.
struct LibrarySidebar: View {
    @EnvironmentObject private var library: LibraryStore
    @Binding var selectedBookID: String?

    @State private var sortMode: LibraryView.SortMode = .lastOpened

    private var sorted: [BookEntity] {
        switch sortMode {
        case .lastOpened:
            return library.books.sorted {
                ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
            }
        case .title:
            return library.books.sorted {
                $0.resolvedTitle.localizedCompare($1.resolvedTitle) == .orderedAscending
            }
        case .addedDate:
            return library.books.sorted { $0.addedAt > $1.addedAt }
        }
    }

    var body: some View {
        Group {
            if library.books.isEmpty {
                emptyState
            } else {
                List(selection: $selectedBookID) {
                    ForEach(sorted) { book in
                        LibrarySidebarRow(book: book)
                            .tag(book.id as String?)
                            .contextMenu {
                                Button(role: .destructive) {
                                    if selectedBookID == book.id {
                                        selectedBookID = nil
                                    }
                                    library.remove(id: book.id)
                                } label: { Label("Remove from library", systemImage: "trash") }
                            }
                    }
                }
                #if os(macOS)
                .listStyle(.sidebar)
                #else
                .listStyle(.plain)
                #endif
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Menu {
                    Picker("Sort by", selection: $sortMode) {
                        ForEach(LibraryView.SortMode.allCases) { Text($0.label).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down.circle") }
            }
        }
    }

    private var emptyState: some View {
        CompatContentUnavailableView(
            "Library is empty",
            systemImage: "books.vertical",
            description: Text("Add an EPUB from the iPhone layout, then come back to the split view.")
        )
    }
}

/// One row in the sidebar. Small cover thumb + two lines.
private struct LibrarySidebarRow: View {
    let book: BookEntity

    var body: some View {
        HStack(spacing: 10) {
            thumb
                .frame(width: 36, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(book.resolvedTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                statusPill
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var thumb: some View {
        if let data = book.coverPNG, let img = platformImage(from: data) {
            img.resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.25),
                             Color.accentColor.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "book.closed")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch book.status {
        case .textOnly:
            EmptyView()
        case .caching:
            Text("Caching")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .offlineReady:
            Text("Offline")
                .font(.caption2)
                .foregroundStyle(.green)
        }
    }

    private func platformImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #endif
        #if canImport(AppKit)
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
    }
}

#if DEBUG
#Preview("Sidebar — populated") {
    LibrarySidebar(selectedBookID: .constant(nil))
        .environmentObject(LibraryStore.previewPopulated)
        .environmentObject(AppSettings())
}

#Preview("Sidebar — empty") {
    LibrarySidebar(selectedBookID: .constant(nil))
        .environmentObject(LibraryStore.previewEmpty)
        .environmentObject(AppSettings())
}
#endif
