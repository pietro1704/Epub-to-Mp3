import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showingPicker = false
    @State private var importError: String?
    @State private var isDropTargeted = false

    private static let acceptedTypes: [UTType] = {
        // EPUB + PDF — same UTI list as `LibraryView` so the import
        // surfaces stay symmetrical between phone and sidebar.
        var types: [UTType] = [.epub, .pdf]
        if let zip = UTType("org.idpf.epub-container") { types.append(zip) }
        return types
    }()

    /// Drop modifier accepts a superset of `acceptedTypes` — on macOS
    /// it also handles generic file URLs from Finder.
    private static var dropTypes: [UTType] {
        LibraryDropHandler.acceptedTypes
    }

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
                            // Swipe-to-delete is the HIG-canonical List
                            // affordance and — critically — does not
                            // route through ``UIContextMenuInteraction``,
                            // so it doesn't trigger the iOS 18+
                            // ``_UIMagicMorphView``/``_UIReparentingView``
                            // "not supported as subview" console warnings
                            // that ``.contextMenu`` emits inside a List.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    if selectedBookID == book.id {
                                        selectedBookID = nil
                                    }
                                    library.remove(id: book.id)
                                } label: {
                                    Label(L10n.string("common.remove"), systemImage: "trash")
                                }
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
        .overlay(DropTargetOverlay(isActive: isDropTargeted))
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .onDrop(
            of: Self.dropTypes,
            isTargeted: $isDropTargeted,
            perform: handleDrop
        )
        .navigationTitle(L10n.string("library.title"))
        .toolbar {
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Menu {
                    Picker(L10n.string("library.sortBy"), selection: $sortMode) {
                        ForEach(LibraryView.SortMode.allCases) { Text($0.label).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down.circle") }
            }
            ToolbarItem(placement: .compatPrimaryTrailing) {
                Button {
                    showingPicker = true
                } label: { Image(systemName: "plus.circle.fill") }
                .accessibilityIdentifier("library.importButton")
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
        .alert(L10n.string("library.importError"),
               isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
               )) {
            Button(L10n.string("library.ok")) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            CompatContentUnavailableView(
                L10n.string("librarySidebar.emptyTitle"),
                systemImage: "books.vertical",
                description: Text(localized: "librarySidebar.emptyDescription")
            )
            Button {
                showingPicker = true
            } label: {
                Label(L10n.string("librarySidebar.importBook"), systemImage: "plus.circle.fill")
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel(L10n.string("librarySidebar.importBook"))
            .accessibilityIdentifier("library.importButton.empty")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }

    /// Imports one or more EPUB URLs into the library store. Mirrors
    /// `LibraryView.handleImport` — kept duplicated rather than
    /// extracted so the sidebar can evolve independently of the
    /// poster-style grid view if/when import UX diverges.
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var firstError: String?
            for url in urls {
                do {
                    _ = try library.importBook(from: url)
                } catch {
                    if firstError == nil {
                        firstError = error.localizedDescription
                    }
                }
            }
            importError = firstError
        case .failure(let err):
            importError = err.localizedDescription
        }
    }

    /// Drag-and-drop entry point — mirrors `handleImport` but accepts
    /// `NSItemProvider` payloads (the SwiftUI drop API). Errors are
    /// surfaced through the same alert as the file-picker path.
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

/// One row in the sidebar. Small cover thumb + two lines.
private struct LibrarySidebarRow: View {
    let book: BookEntity

    var body: some View {
        // Sidebar row uses the 8/12/16/20 spacing grid:
        // - 12pt between thumb and text column
        // - 4pt between text rows (HIG tight-stack rhythm)
        // - 4pt vertical row padding so consecutive rows breathe
        HStack(spacing: 12) {
            thumb
                .frame(width: 40, height: 60) // on-grid 2:3 ratio
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
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
        .padding(.vertical, 4)
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
                Image(systemName: book.fileType == .pdf
                      ? "doc.richtext"
                      : "book.closed")
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
            Text(localized: "library.caching")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .offlineReady:
            Text(localized: "library.offline")
                .font(.caption2)
                .foregroundStyle(.green)
        }
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
