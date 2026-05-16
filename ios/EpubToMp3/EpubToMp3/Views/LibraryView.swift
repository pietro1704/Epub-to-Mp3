import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The hero of the app. Lists every EPUB the user has imported.
/// Tapping a book takes them straight to the reader/player. Adding a
/// book is a small + button in the toolbar that triggers the system
/// file picker.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var showingPicker = false
    @State private var importError: String?
    @State private var openingBook: BookEntity?
    @State private var sortMode: SortMode = .lastOpened
    @State private var isDropTargeted = false
    /// Book the user long-pressed on; surfaced via
    /// ``confirmationDialog`` instead of ``.contextMenu``. The latter
    /// invokes ``UIContextMenuInteraction``, which on iOS 18+ floods the
    /// console with ``_UIMagicMorphView`` / ``_UIReparentingView``
    /// "not supported" warnings when the previewed view is hosted
    /// inside a ``LazyVGrid``. A confirmation dialog covers the only
    /// destructive action (remove from library) without entering the
    /// UIKit context-menu morph code path.
    @State private var bookPendingRemoval: BookEntity?
    @State private var selectedTag: String?
    @State private var bookForTagEditor: BookEntity?

    enum SortMode: String, CaseIterable, Identifiable {
        case lastOpened
        case title
        case addedDate
        var id: String { rawValue }
        var label: String {
            switch self {
            case .lastOpened: return "Last opened"
            case .title:      return "Title"
            case .addedDate:  return "Date added"
            }
        }
    }

    private var sorted: [BookEntity] {
        let base: [BookEntity]
        if let tag = selectedTag {
            base = library.books(withTag: tag)
        } else {
            base = library.books
        }
        switch sortMode {
        case .lastOpened:
            return base.sorted {
                ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
            }
        case .title:
            return base.sorted { $0.resolvedTitle.localizedCompare($1.resolvedTitle) == .orderedAscending }
        case .addedDate:
            return base.sorted { $0.addedAt > $1.addedAt }
        }
    }

    private static let acceptedTypes: [UTType] = {
        // EPUB + PDF — same picker / drop surface. The Library tile
        // shows a per-book glyph so the user can tell them apart at
        // a glance once imported.
        var types: [UTType] = [.epub, .pdf]
        if let zip = UTType("org.idpf.epub-container") { types.append(zip) }
        return types
    }()

    /// Drop modifier accepts a superset of `acceptedTypes` —
    /// on macOS it also takes generic file URLs from Finder, which the
    /// `fileImporter` doesn't need to worry about.
    private static var dropTypes: [UTType] {
        LibraryDropHandler.acceptedTypes
    }

    private var grid: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)]
    }

    var body: some View {
        Group {
            if library.books.isEmpty {
                emptyState
            } else {
                ScrollView {
                    tagFilterBar
                    LazyVGrid(columns: grid, spacing: 24) {
                        ForEach(sorted) { book in
                            BookTile(book: book) {
                                // Mark this book as the user's current
                                // reading target so the Read tab lands
                                // on it next time they switch back.
                                // Without this write the Read tab keeps
                                // showing whatever was last set by the
                                // MainReaderView itself, which never
                                // observed taps in the Library grid.
                                UserDefaults.standard.set(
                                    book.id,
                                    forKey: MainReaderView.currentlyReadingBookIDKey
                                )
                                openingBook = book
                            }
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.45)
                                    .onEnded { _ in bookPendingRemoval = book }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .overlay(DropTargetOverlay(isActive: isDropTargeted))
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .onDrop(
            of: Self.dropTypes,
            isTargeted: $isDropTargeted,
            perform: handleDrop
        )
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Menu {
                    Picker("Sort by", selection: $sortMode) {
                        ForEach(SortMode.allCases) { Text($0.label).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down.circle") }
            }
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Button {
                    showingPicker = true
                } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .background {
            Color.clear.allowsHitTesting(false)
                .fileImporter(
                    isPresented: $showingPicker,
                    allowedContentTypes: Self.acceptedTypes,
                    allowsMultipleSelection: true
                ) { result in
                    handleImport(result)
                }
        }
        .alert("Import error",
               isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
               )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .compatBookDestination($openingBook)
        .confirmationDialog(
            bookPendingRemoval?.resolvedTitle ?? "Remove book",
            isPresented: Binding(
                get: { bookPendingRemoval != nil },
                set: { if !$0 { bookPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: bookPendingRemoval
        ) { book in
            Button("Edit Tags") {
                bookPendingRemoval = nil
                bookForTagEditor = book
            }
            Button("Remove from library", role: .destructive) {
                library.remove(id: book.id)
                bookPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { bookPendingRemoval = nil }
        }
        .sheet(item: $bookForTagEditor) { book in
            TagEditorSheet(book: book)
                .environmentObject(library)
        }
    }

    @ViewBuilder
    private var tagFilterBar: some View {
        let tags = library.allTags
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        selectedTag = nil
                    } label: {
                        Text("All")
                            .font(.callout.weight(selectedTag == nil ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selectedTag == nil
                                    ? AnyShapeStyle(.tint.opacity(0.2))
                                    : AnyShapeStyle(.quaternary),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            selectedTag = (selectedTag == tag) ? nil : tag
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "tag.fill")
                                    .font(.caption2)
                                Text(tag)
                            }
                            .font(.callout.weight(selectedTag == tag ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selectedTag == tag
                                    ? AnyShapeStyle(.tint.opacity(0.2))
                                    : AnyShapeStyle(.quaternary),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("Your library is empty.")
                .font(.title3)
            Text("Tap + to import an EPUB or PDF, or share one from Apple Books, Files, or Safari.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                showingPicker = true
            } label: {
                Label("Add Book", systemImage: "plus")
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Subtle hint about the DRM limitation. Books purchased
            // from the iBookstore are FairPlay-protected and Apple
            // does not expose their content to third-party apps.
            Text("Books purchased from Apple Books are DRM-protected and cannot be opened by third-party apps.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var firstError: String?
            for url in urls {
                do {
                    _ = try library.importBook(from: url)
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            importError = firstError
        case .failure(let err):
            importError = err.localizedDescription
        }
    }

    /// Drag-and-drop entry point — mirrors `handleImport` but accepts
    /// `NSItemProvider` payloads (the SwiftUI drop API). EPUBs that
    /// dedupe against existing library entries simply refresh the
    /// bookmark inside `LibraryStore.importBook` — no error surfaces.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        LibraryDropHandler.handle(
            providers: providers,
            importer: { url in _ = try library.importBook(from: url) },
            completion: { firstError, _ in
                if let err = firstError { importError = err }
            }
        )
    }
}

/// Single book tile — cover above, title + author below, status pill
/// in the corner. Big tap target.
struct BookTile: View {
    let book: BookEntity
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    cover
                        .aspectRatio(2.0/3.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(.tint.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.tint.opacity(0.18), lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    statusBadge
                        .padding(8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.resolvedTitle)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let author = book.author, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cover: some View {
        if let data = book.coverPNG, let img = platformImage(from: data) {
            img.resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.25),
                                         Color.accentColor.opacity(0.08)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                Image(systemName: book.fileType == .pdf
                      ? "doc.richtext"
                      : "book.closed")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch book.status {
        case .textOnly:
            EmptyView()
        case .caching:
            badgeLabel("Caching", systemImage: "icloud.and.arrow.down", tint: .orange)
        case .offlineReady:
            badgeLabel("Offline", systemImage: "checkmark.seal.fill", tint: .green)
        }
    }

    private func badgeLabel(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.thinMaterial, in: Capsule())
        .foregroundStyle(tint)
    }

}

/// `.navigationDestination(item:)` requires iOS 17 / macOS 14.
/// Older OSes get a value-based `NavigationLink(isActive:)` rendered
/// invisibly behind the grid — same UX (tap a tile, push detail).
private extension View {
    @ViewBuilder
    func compatBookDestination(_ binding: Binding<BookEntity?>) -> some View {
        if #available(iOS 17, macOS 14, *) {
            self.navigationDestination(item: binding) { book in
                BookOpenView(book: book)
            }
        } else {
            // Hidden NavigationLink driven by the optional binding —
            // SwiftUI pushes when `binding.wrappedValue` flips non-nil
            // and pops when it returns to nil.
            self.background(
                NavigationLink(
                    isActive: Binding(
                        get: { binding.wrappedValue != nil },
                        set: { active in
                            if !active { binding.wrappedValue = nil }
                        }
                    ),
                    destination: {
                        if let book = binding.wrappedValue {
                            BookOpenView(book: book)
                        } else {
                            EmptyView()
                        }
                    },
                    label: { EmptyView() }
                )
                .hidden()
            )
        }
    }
}

#if DEBUG
#Preview("Library — empty") {
    CompatNavigationStack { LibraryView() }
        .environmentObject(LibraryStore.previewEmpty)
        .environmentObject(AppSettings())
}

#Preview("Library — populated") {
    CompatNavigationStack { LibraryView() }
        .environmentObject(LibraryStore.previewPopulated)
        .environmentObject(AppSettings())
}
#endif
