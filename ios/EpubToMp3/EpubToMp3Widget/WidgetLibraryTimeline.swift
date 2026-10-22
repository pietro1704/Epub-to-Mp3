import WidgetKit
import Foundation

struct LibraryEntry: TimelineEntry {
    let date: Date
    let books: [LibraryBookItem]

    struct LibraryBookItem: Identifiable {
        let id: String
        let title: String
        let author: String?
        let coverData: Data?
    }

    static var placeholder: LibraryEntry {
        LibraryEntry(date: Date(), books: [
            LibraryBookItem(id: "1", title: "Foundation", author: "Isaac Asimov", coverData: nil),
            LibraryBookItem(id: "2", title: "Metro 2033", author: "Dmitry Glukhovsky", coverData: nil),
            LibraryBookItem(id: "3", title: "O Hobbit", author: "J.R.R. Tolkien", coverData: nil),
            LibraryBookItem(id: "4", title: "Dune", author: "Frank Herbert", coverData: nil),
            LibraryBookItem(id: "5", title: "Neuromancer", author: "William Gibson", coverData: nil),
            LibraryBookItem(id: "6", title: "1984", author: "George Orwell", coverData: nil),
        ])
    }

    static var empty: LibraryEntry {
        LibraryEntry(date: Date(), books: [])
    }
}

struct LibraryProvider: TimelineProvider {
    func placeholder(in context: Context) -> LibraryEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (LibraryEntry) -> Void) {
        completion(context.isPreview ? .placeholder : loadLibrary())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LibraryEntry>) -> Void) {
        let entry = loadLibrary()
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    func loadLibrary(defaults: UserDefaults? = WidgetSharedLibrary.defaults()) -> LibraryEntry {
        let books = WidgetSharedLibrary.loadBooks(defaults: defaults)
        guard !books.isEmpty else { return .empty }

        // Sort by most recently opened, then by most recently added.
        let sorted = books.sorted { a, b in
            (a.lastOpenedAt ?? .distantPast) > (b.lastOpenedAt ?? .distantPast)
        }

        let items = sorted.prefix(6).map { book in
            LibraryEntry.LibraryBookItem(
                id: book.id,
                title: book.title,
                author: book.author,
                coverData: book.coverPNG
            )
        }

        return LibraryEntry(date: Date(), books: items)
    }
}
