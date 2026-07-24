import SwiftUI

#if canImport(UIKit)
import UIKit

/// UIKit chapter list backing the middle `NavigationSplitView` column
/// (`ChapterListColumn`). A `UICollectionViewController` with a plain list
/// configuration replaces the SwiftUI `List` on iOS/iPadOS — cell reuse +
/// diffable snapshots avoid `List`'s per-row diffing cost on long books.
///
/// See docs/plans/uikit-performance-migration.md (Phase 1, slice 2).
struct ChapterListCollectionView: UIViewControllerRepresentable {
    var rows: [ChapterListRowModel]
    @Binding var selectedChapterIndex: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: { selectedChapterIndex = $0 })
    }

    func makeUIViewController(context: Context) -> ChapterListController {
        let controller = ChapterListController()
        controller.coordinator = context.coordinator
        controller.apply(rows: rows, selected: selectedChapterIndex, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: ChapterListController, context: Context) {
        context.coordinator.onSelect = { selectedChapterIndex = $0 }
        controller.apply(rows: rows, selected: selectedChapterIndex, animated: true)
    }

    final class Coordinator {
        var onSelect: (Int?) -> Void
        init(onSelect: @escaping (Int?) -> Void) { self.onSelect = onSelect }
    }
}

/// The `UICollectionViewController` that owns the diffable list data source.
final class ChapterListController: UICollectionViewController {
    private enum Section { case main }

    weak var coordinator: ChapterListCollectionView.Coordinator?

    private var rowsByID: [Int: ChapterListRowModel] = [:]
    private var dataSource: UICollectionViewDiffableDataSource<Section, Int>!

    init() {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = true
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        super.init(collectionViewLayout: layout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> {
            [weak self] cell, _, id in
            guard let row = self?.rowsByID[id] else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.title
            content.secondaryText = row.charsText
            content.textProperties.numberOfLines = 2
            content.image = UIImage(systemName: row.isCompleted ? "checkmark.circle.fill" : "circle.dashed")
            content.imageProperties.tintColor = row.isCompleted ? .systemGreen : .secondaryLabel
            cell.contentConfiguration = content

            if let durationText = row.durationText {
                let label = UILabel()
                label.text = durationText
                label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                label.textColor = .secondaryLabel
                label.sizeToFit()
                cell.accessories = [.customView(configuration: .init(customView: label, placement: .trailing()))]
            } else {
                cell.accessories = []
            }
            cell.accessibilityLabel = row.accessibilityLabel
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Int>(
            collectionView: collectionView
        ) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    func apply(rows: [ChapterListRowModel], selected: Int?, animated: Bool) {
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Section, Int>()
        snapshot.appendSections([.main])
        snapshot.appendItems(rows.map(\.id), toSection: .main)
        // Data source may be nil if called before viewDidLoad.
        guard dataSource != nil else { return }
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            self?.syncSelection(selected)
        }
    }

    private func syncSelection(_ selected: Int?) {
        guard let selected, let indexPath = dataSource.indexPath(for: selected) else {
            collectionView.indexPathsForSelectedItems?.forEach {
                collectionView.deselectItem(at: $0, animated: false)
            }
            return
        }
        guard collectionView.indexPathsForSelectedItems?.contains(indexPath) != true else { return }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        coordinator?.onSelect(id)
    }
}
#endif
