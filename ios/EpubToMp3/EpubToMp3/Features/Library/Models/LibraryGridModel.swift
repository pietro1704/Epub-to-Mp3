import Foundation

/// Pure, UIKit-free ordering/filtering pipeline for the library grid.
///
/// This is the data-source model that the UIKit `UICollectionView`
/// migration (see `docs/plans/uikit-performance-migration.md`) consumes
/// to build a diffable snapshot. It is deliberately free of SwiftUI and
/// UIKit so it can be unit-tested off-device — the only layer verifiable
/// without a device build. The UIKit view layer stays a thin mapping from
/// `arrangedBooks()` onto `NSDiffableDataSourceSnapshot`.
///
/// Sorting and filtering are shared by the UIKit and AppKit library views:
/// optional tag filter → case-insensitive search over title/author/tags →
/// sort by the selected mode.
struct LibraryGridModel: Equatable {

    enum SortMode: String, CaseIterable, Identifiable {
        case lastPlayed
        case lastOpened
        case title
        case addedDate
        var id: String { rawValue }

        private static let preferenceKey = "library.sortMode.v1"

        static func saved(in defaults: UserDefaults = .standard) -> Self {
            defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .lastPlayed
        }

        func save(in defaults: UserDefaults = .standard) {
            defaults.set(rawValue, forKey: Self.preferenceKey)
        }

        var label: String {
            switch self {
            case .lastPlayed: return L10n.string("library.lastPlayed")
            case .lastOpened: return L10n.string("library.lastOpened")
            case .title: return L10n.string("library.titleSort")
            case .addedDate: return L10n.string("library.dateAdded")
            }
        }
    }

    var books: [BookEntity]
    var selectedTag: String?
    var searchQuery: String
    var sortMode: SortMode

    init(
        books: [BookEntity],
        selectedTag: String? = nil,
        searchQuery: String = "",
        sortMode: SortMode = .lastPlayed
    ) {
        self.books = books
        self.selectedTag = selectedTag
        self.searchQuery = searchQuery
        self.sortMode = sortMode
    }

    /// Ordered, filtered books ready to become a diffable snapshot.
    func arrangedBooks() -> [BookEntity] {
        var base = books
        if let tag = selectedTag {
            base = base.filter { $0.tags.contains(tag) }
        }
        let query = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !query.isEmpty {
            base = base.filter { book in
                book.resolvedTitle.lowercased().contains(query)
                    || (book.author?.lowercased().contains(query) ?? false)
                    || book.tags.contains { $0.lowercased().contains(query) }
            }
        }
        switch sortMode {
        case .lastPlayed:
            // "Recently read or played": opening a book to read or to listen puts it first at once, without
            // waiting for audio; playing later moves it again. Never-touched books follow in added order.
            return base.sorted { lhs, rhs in
                let (left, right) = (lhs.lastInteractionAt, rhs.lastInteractionAt)
                if left != right { return left > right }
                return lhs.addedAt > rhs.addedAt
            }
        case .lastOpened:
            return base.sorted {
                ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
            }
        case .title:
            return base.sorted {
                $0.resolvedTitle.localizedCompare($1.resolvedTitle) == .orderedAscending
            }
        case .addedDate:
            return base.sorted { $0.addedAt > $1.addedAt }
        }
    }
}
