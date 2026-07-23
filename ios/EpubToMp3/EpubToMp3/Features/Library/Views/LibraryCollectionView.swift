import Foundation

/// Pure layout metrics for the library grid, shared by the SwiftUI and
/// UIKit renderers. Kept UIKit-free so it is unit-testable off-device.
///
/// Mirrors the SwiftUI grid: adaptive tiles between `minTileWidth` and
/// `maxTileWidth` with `spacing` gutters and `sectionInset` on each edge.
struct LibraryGridLayoutMetrics: Equatable {
    var minTileWidth: CGFloat = 160
    var maxTileWidth: CGFloat = 220
    var spacing: CGFloat = 20
    var sectionInset: CGFloat = 20

    /// Number of columns that fit in `availableWidth`, matching
    /// `GridItem(.adaptive(minimum:maximum:))` semantics: pack as many
    /// `minTileWidth` tiles (plus gutters) as fit, at least one.
    func columnCount(forWidth availableWidth: CGFloat) -> Int {
        let usable = availableWidth - 2 * sectionInset
        guard usable > 0 else { return 1 }
        // n tiles need n*min + (n-1)*spacing <= usable.
        let n = Int((usable + spacing) / (minTileWidth + spacing))
        return max(1, n)
    }

    /// Actual tile width for a given column count, clamped to the max.
    func tileWidth(forWidth availableWidth: CGFloat, columns: Int) -> CGFloat {
        let columns = max(1, columns)
        let usable = availableWidth - 2 * sectionInset - spacing * CGFloat(columns - 1)
        let raw = usable / CGFloat(columns)
        return min(max(raw, 0), maxTileWidth)
    }
}

#if canImport(UIKit)
import UIKit
import SwiftUI

/// UIKit book grid backing the library hero. A `UICollectionView` with a
/// compositional layout, diffable data source and cell prefetching
/// replaces the SwiftUI `LazyVGrid` on iOS/iPadOS for O(visible) scroll
/// cost and zero view-tree re-evaluation. Hosted inside the existing
/// SwiftUI `LibraryView` chrome via `UIViewControllerRepresentable`.
///
/// See docs/plans/uikit-performance-migration.md (Phase 1, slice 1).
struct LibraryCollectionView: UIViewControllerRepresentable {
    var model: LibraryGridModel
    var metrics: LibraryGridLayoutMetrics = .init()
    var onOpen: (BookEntity) -> Void
    var onRemove: (BookEntity) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpen: onOpen, onRemove: onRemove)
    }

    func makeUIViewController(context: Context) -> LibraryGridController {
        let controller = LibraryGridController(metrics: metrics)
        controller.coordinator = context.coordinator
        controller.apply(model: model, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: LibraryGridController, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.onRemove = onRemove
        controller.apply(model: model, animated: true)
    }

    final class Coordinator {
        var onOpen: (BookEntity) -> Void
        var onRemove: (BookEntity) -> Void
        init(onOpen: @escaping (BookEntity) -> Void, onRemove: @escaping (BookEntity) -> Void) {
            self.onOpen = onOpen
            self.onRemove = onRemove
        }
    }
}

/// The `UICollectionViewController` that owns the diffable data source.
final class LibraryGridController: UICollectionViewController {
    private enum Section { case main }

    private let metrics: LibraryGridLayoutMetrics
    weak var coordinator: LibraryCollectionView.Coordinator?

    /// id → book, so selection/context callbacks can hand back the entity.
    private var booksByID: [String: BookEntity] = [:]
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!

    init(metrics: LibraryGridLayoutMetrics) {
        self.metrics = metrics
        super.init(collectionViewLayout: LibraryGridController.makeLayout(metrics: metrics))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeLayout(metrics: LibraryGridLayoutMetrics) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = metrics.columnCount(forWidth: width)
            let fraction = 1.0 / CGFloat(columns)
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .fractionalHeight(1.0)
                )
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(fraction),
                    heightDimension: .estimated(240)
                ),
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = metrics.spacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: metrics.sectionInset,
                leading: metrics.sectionInset,
                bottom: metrics.sectionInset,
                trailing: metrics.sectionInset
            )
            return section
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true

        let registration = UICollectionView.CellRegistration<BookGridCell, String> {
            [weak self] cell, _, id in
            guard let book = self?.booksByID[id] else { return }
            cell.configure(with: book)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, String>(
            collectionView: collectionView
        ) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(
                using: registration, for: indexPath, item: id
            )
        }
    }

    func apply(model: LibraryGridModel, animated: Bool) {
        let books = model.arrangedBooks()
        booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(books.map(\.id), toSection: .main)
        // Data source may be nil if called before viewDidLoad.
        guard dataSource != nil else { return }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let book = booksByID[id] else { return }
        coordinator?.onOpen(book)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let book = booksByID[id] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let remove = UIAction(
                title: L10n.string("library.removeBook"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in self?.coordinator?.onRemove(book) }
            return UIMenu(children: [remove])
        }
    }
}

/// A single book tile: cover image over title/author labels.
final class BookGridCell: UICollectionViewCell {
    private let cover = UIImageView()
    private let title = UILabel()
    private let author = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.layer.cornerRadius = 8
        cover.backgroundColor = .secondarySystemFill
        cover.setContentHuggingPriority(.defaultLow, for: .vertical)

        title.font = .preferredFont(forTextStyle: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 2

        author.font = .preferredFont(forTextStyle: .caption1)
        author.adjustsFontForContentSizeCategory = true
        author.textColor = .secondaryLabel
        author.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [cover, title, author])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor, multiplier: 1.5)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with book: BookEntity) {
        title.text = book.resolvedTitle
        author.text = book.author
        author.isHidden = (book.author?.isEmpty ?? true)
        if let data = book.coverPNG, let image = UIImage(data: data) {
            cover.image = image
        } else {
            cover.image = UIImage(systemName: "book.closed")
        }
        accessibilityIdentifier = "library.bookTile.\(book.id)"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cover.image = nil
        title.text = nil
        author.text = nil
    }
}
#endif
