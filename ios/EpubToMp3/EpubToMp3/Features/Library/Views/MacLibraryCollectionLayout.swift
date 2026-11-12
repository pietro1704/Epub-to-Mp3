#if os(macOS)
import AppKit

/// Responsive requested columns, including the width of a non-overlay scroller.
final class MacLibraryCollectionLayout: NSCollectionViewFlowLayout {
    var requestedColumns = 2
    override init() {
        super.init()
        minimumInteritemSpacing = 18
        minimumLineSpacing = 24
        sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func updateItemSize() {
        guard let collectionView else { return }
        let viewportWidth = collectionView.enclosingScrollView?.contentView.bounds.width
            ?? collectionView.bounds.width
        let metrics = LibraryGridLayoutMetrics(spacing: minimumInteritemSpacing,
            sectionInset: max(sectionInset.left, sectionInset.right), requestedColumns: requestedColumns)
        let columns = metrics.columnCount(forWidth: viewportWidth)
        let width = floor(metrics.tileWidth(forWidth: viewportWidth, columns: columns))
        let size = NSSize(width: width, height: width * 1.5 + 110)
        let documentWidthChanged = collectionView.frame.width != viewportWidth
        guard itemSize != size || documentWidthChanged else { return }
        if documentWidthChanged {
            collectionView.setFrameSize(NSSize(width: viewportWidth, height: collectionView.frame.height))
        }
        itemSize = size
        invalidateLayout()
        collectionView.needsLayout = true
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
            || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

#endif
