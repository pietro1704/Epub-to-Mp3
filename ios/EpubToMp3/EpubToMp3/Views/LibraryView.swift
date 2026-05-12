import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
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
        switch sortMode {
        case .lastOpened:
            return library.books.sorted {
                ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
            }
        case .title:
            return library.books.sorted { $0.resolvedTitle.localizedCompare($1.resolvedTitle) == .orderedAscending }
        case .addedDate:
            return library.books.sorted { $0.addedAt > $1.addedAt }
        }
    }

    private static let acceptedTypes: [UTType] = {
        var types: [UTType] = [.epub]
        if let zip = UTType("org.idpf.epub-container") { types.append(zip) }
        return types
    }()

    private var grid: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)]
    }

    var body: some View {
        Group {
            if library.books.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: grid, spacing: 24) {
                        ForEach(sorted) { book in
                            BookTile(book: book) {
                                openingBook = book
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    library.remove(id: book.id)
                                } label: { Label("Remove from library", systemImage: "trash") }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
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
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: Self.acceptedTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
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
        .navigationDestination(item: $openingBook) { book in
            BookOpenView(book: book)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("Your library is empty.")
                .font(.title3)
            Text("Add an EPUB from your disk to start reading and listening.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                showingPicker = true
            } label: {
                Label("Add EPUB", systemImage: "plus")
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
                Image(systemName: "book.closed")
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
#Preview("Library — empty") {
    NavigationStack { LibraryView() }
        .environmentObject(LibraryStore.previewEmpty)
        .environmentObject(AppSettings())
}

#Preview("Library — populated") {
    NavigationStack { LibraryView() }
        .environmentObject(LibraryStore.previewPopulated)
        .environmentObject(AppSettings())
}
#endif
