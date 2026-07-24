import SwiftUI

#if os(iOS)
struct BookmarksListView: View {
    let bookId: String
    var onJumpToChapter: ((Int) -> Void)?

    var body: some View {
        EmptyView()
    }
}
#else
struct BookmarksListView: View {
    let bookId: String
    var onJumpToChapter: ((Int) -> Void)?

    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @State private var filter: Filter = .all
    @State private var editingBookmark: Bookmark?

    enum Filter: String, CaseIterable, Identifiable {
        case all, bookmarks, highlights
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return L10n.string("bookmarks.filter.all")
            case .bookmarks: return L10n.string("bookmarks.filter.bookmarks")
            case .highlights: return L10n.string("bookmarks.filter.highlights")
            }
        }
    }

    private var filtered: [Bookmark] {
        let all = bookmarkStore.bookmarks(for: bookId)
        switch filter {
        case .all: return all
        case .bookmarks: return all.filter { !$0.isHighlight }
        case .highlights: return all.filter { $0.isHighlight }
        }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filtered) { bm in
                        Button {
                            onJumpToChapter?(bm.chapterIndex)
                        } label: {
                            BookmarkRow(bookmark: bm)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    bookmarkStore.remove(id: bm.id)
                                } label: { Label(L10n.string("common.delete"), systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    editingBookmark = bm
                                } label: { Label(L10n.string("bookmarks.note"), systemImage: "pencil") }
                                    .tint(.blue)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(L10n.string("player.bookmarks"))
        .toolbar {
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Picker(L10n.string("bookmarks.filter"), selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
        }
        .sheet(item: $editingBookmark) { bm in
            NoteEditorSheet(bookmark: bm)
                .environmentObject(bookmarkStore)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(localized: "bookmarks.emptyTitle")
                .font(.title3)
            Text(localized: "bookmarks.emptyDescription")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif

struct BookmarkRow: View {
    let bookmark: Bookmark

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if bookmark.isHighlight {
                RoundedRectangle(cornerRadius: 2)
                    .fill(bookmark.color.swiftUIColor)
                    .frame(width: 4)
            } else {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(bookmark.chapterTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if bookmark.isHighlight {
                    Text(bookmark.selectedText)
                        .font(.body)
                        .lineLimit(3)
                }
                if let note = bookmark.note, !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(bookmark.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bookmark.isHighlight
            ? L10n.string("bookmarks.a11y.highlight", bookmark.chapterTitle, bookmark.selectedText)
            : L10n.string("bookmarks.a11y.bookmark", bookmark.chapterTitle))
    }
}

struct NoteEditorSheet: View {
    let bookmark: Bookmark
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @Environment(\.dismiss) private var dismiss
    @State private var noteText: String = ""

    var body: some View {
        CompatNavigationStack {
            Form {
                Section(L10n.string("bookmarks.note")) {
                    TextEditor(text: $noteText)
                        .frame(minHeight: 120)
                }
                if bookmark.isHighlight {
                    Section(L10n.string("bookmarks.highlightedText")) {
                        Text(bookmark.selectedText)
                            .foregroundStyle(.secondary)
                    }
                    Section(L10n.string("bookmarks.color")) {
                        HStack(spacing: 12) {
                            ForEach(HighlightColor.allCases) { c in
                                Button {
                                        bookmarkStore.updateColor(id: bookmark.id, color: c)
                                } label: {
                                    Circle()
                                        .fill(c.swiftUIColor)
                                        .frame(width: 32, height: 32)
                                        .overlay {
                                            if c == bookmark.color {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.bold())
                                                    .foregroundStyle(.white)
                                                    .accessibilityHidden(true)
                                            }
                                        }
                                }
                                .frame(width: 44, height: 44)
                                .buttonStyle(.plain)
                                .accessibilityLabel(c == bookmark.color
                                    ? L10n.string("bookmarks.colorSelected", c.rawValue)
                                    : L10n.string("bookmarks.colorOption", c.rawValue))
                                .accessibilityAddTraits(c == bookmark.color ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.string("bookmarks.editNote"))
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("general.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.save")) {
                        bookmarkStore.updateNote(id: bookmark.id, note: noteText.isEmpty ? nil : noteText)
                        dismiss()
                    }
                }
            }
            .onAppear { noteText = bookmark.note ?? "" }
        }
    }
}

extension HighlightColor {
    var swiftUIColor: Color {
        switch self {
        case .yellow: return .yellow
        case .blue:   return .blue
        case .green:  return .green
        case .pink:   return .pink
        case .orange: return .orange
        }
    }
}

#if DEBUG
#Preview("Bookmarks — populated") {
    CompatNavigationStack {
        BookmarksListView(bookId: "preview-1")
    }
    .environmentObject(BookmarkStore.previewPopulated)
}
#endif
