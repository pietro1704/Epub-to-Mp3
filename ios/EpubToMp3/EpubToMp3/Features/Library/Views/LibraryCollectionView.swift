import Foundation

/// Pure layout metrics for the native library grid. Kept UIKit-free so it
/// is unit-testable off-device.
///
/// Packs adaptive tiles between `minTileWidth` and `maxTileWidth` with
/// `spacing` gutters and `sectionInset` on each edge.
struct LibraryGridLayoutMetrics: Equatable {
    var minTileWidth: CGFloat = 160
    var maxTileWidth: CGFloat = 220
    var spacing: CGFloat = 20
    var sectionInset: CGFloat = 20

    /// Number of columns that fit in `availableWidth`, packing as many
    /// minimum-width tiles (plus gutters) as fit, at least one.
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
import ImageIO

/// The `UICollectionViewController` that owns the diffable data source.
final class LibraryGridController: UICollectionViewController {
    private enum Section { case main }

    private let metrics: LibraryGridLayoutMetrics
    var onOpen: ((BookEntity) -> Void)?
    var onRemove: ((BookEntity) -> Void)?

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
        onOpen?(book)
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
            ) { [weak self] _ in self?.onRemove?(book) }
            return UIMenu(children: [remove])
        }
    }
}

/// Off-main-thread cover thumbnail decode + memory-bounded cache, scoped to
/// the library grid tile size. `UIImage(data:)` decodes to the SOURCE
/// resolution (a 3000×3000 cover PNG is a ~36 MB bitmap) synchronously on
/// the main thread inside `CellRegistration`, which fires on every dequeue
/// while scrolling — the single biggest jank + memory source in the grid.
/// `CGImageSourceCreateThumbnailAtIndex` decodes directly at the requested
/// pixel size instead, off the main thread.
enum LibraryCoverThumbnailCache {
    /// ~220pt max tile width (`LibraryGridLayoutMetrics`) × 3x Retina.
    static let maxPixelSize: CGFloat = 660

    private final class ImageCache: @unchecked Sendable {
        private let lock = NSLock()
        private let storage: NSCache<NSString, UIImage> = {
            let cache = NSCache<NSString, UIImage>()
            // Cost-based, not count-based: a 660px-max thumbnail is at most
            // ~1.7 MB decoded; 96 MB bounds the scrolling working set.
            cache.totalCostLimit = 96 * 1024 * 1024
            return cache
        }()

        func image(for key: NSString) -> UIImage? {
            lock.lock()
            defer { lock.unlock() }
            return storage.object(forKey: key)
        }

        func insert(_ image: UIImage, for key: NSString, cost: Int) {
            lock.lock()
            storage.setObject(image, forKey: key, cost: cost)
            lock.unlock()
        }
    }

    private static let cache = ImageCache()

    static func cached(for bookID: String) -> UIImage? {
        cache.image(for: bookID as NSString)
    }

    /// Decodes off the calling thread's actor — call from a background
    /// `Task`, never directly on main.
    static func decode(_ data: Data, bookID: String) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary)
        else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { return nil }
        let image = UIImage(cgImage: cgImage)
        let cost = cgImage.width * cgImage.height * 4
        cache.insert(image, for: bookID as NSString, cost: cost)
        return image
    }
}

/// A single book tile: cover image over title/author labels.
final class BookGridCell: UICollectionViewCell {
    private let cover = UIImageView()
    private let title = UILabel()
    private let author = UILabel()
    /// Generation token guarding against a stale async decode landing on a
    /// cell the collection view has since recycled for a different book.
    private var configurationToken = UUID()

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
        accessibilityIdentifier = "library.bookTile.\(book.id)"

        let token = UUID()
        configurationToken = token
        cover.image = UIImage(systemName: "book.closed")

        guard let data = book.coverPNG else { return }
        if let hit = LibraryCoverThumbnailCache.cached(for: book.id) {
            cover.image = hit
            return
        }
        Task.detached(priority: .userInitiated) { [bookID = book.id] in
            let decoded = LibraryCoverThumbnailCache.decode(data, bookID: bookID)
            await MainActor.run { [weak self] in
                guard let self, self.configurationToken == token, let decoded else { return }
                self.cover.image = decoded
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configurationToken = UUID()
        cover.image = nil
        title.text = nil
        author.text = nil
    }
}
#endif
