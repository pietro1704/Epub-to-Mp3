import SwiftUI

#if canImport(UIKit)
import UIKit

/// The `UICollectionViewController` that owns the diffable list data source.
final class JobsListController: UICollectionViewController {
    private enum Section { case main }

    var onSelect: ((SessionRecord) -> Void)?

    private var sessionsByID: [String: SessionRecord] = [:]
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!

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
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, _, id in
            guard let session = self?.sessionsByID[id] else { return }
            let row = SessionRowModel.make(from: session)
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.title
            content.secondaryText = row.detailText
            content.textProperties.numberOfLines = 2
            cell.contentConfiguration = content
            var accessories: [UICellAccessory] = []
            if let outcomeText = row.outcomeText {
                let badge = Self.makeBadge(text: outcomeText, color: Self.color(for: row.outcomeState))
                accessories.append(.customView(configuration: .init(customView: badge, placement: .trailing())))
            }
            if session.jobId?.isEmpty == false {
                accessories.append(.disclosureIndicator())
            }
            cell.accessories = accessories
        }
        dataSource = UICollectionViewDiffableDataSource<Section, String>(
            collectionView: collectionView
        ) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    func apply(sessions: [SessionRecord], animated: Bool) {
        sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(sessions.map(\.id), toSection: .main)
        // Data source may be nil if called before viewDidLoad.
        guard dataSource != nil else { return }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let session = sessionsByID[id] else { return }
        onSelect?(session)
    }

    private static func makeBadge(text: String, color: UIColor) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.backgroundColor = color.withAlphaComponent(0.15)
        container.layer.cornerRadius = 8
        container.layer.masksToBounds = true
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        container.frame = CGRect(
            origin: .zero,
            size: container.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        )
        return container
    }

    private static func color(for state: SessionRowModel.OutcomeState) -> UIColor {
        switch state {
        case .success: return .systemGreen
        case .partial: return .systemOrange
        case .failed: return .systemRed
        case .unknown: return .secondaryLabel
        }
    }
}
#endif
