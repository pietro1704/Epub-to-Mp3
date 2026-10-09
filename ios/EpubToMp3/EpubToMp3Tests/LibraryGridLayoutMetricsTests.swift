//
//  LibraryGridLayoutMetricsTests.swift
//  EpubToMp3Tests
//
//  Pure column-math coverage for the library grid layout helpers shared by
//  the remaining grid renderers.
//

import XCTest
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif
@testable import EpubToMp3

final class LibraryGridLayoutMetricsTests: XCTestCase {

    func testPhoneTileReservesSpaceForCoverAndMetadata() {
        let metrics = LibraryGridLayoutMetrics()
        let columns = metrics.columnCount(forWidth: 390)
        let height = metrics.tileWidth(forWidth: 390, columns: columns) * 1.5 + 70

        XCTAssertGreaterThan(height, 300)
    }

    func testColumnCountStaysAtTwoAcrossSupportedWidths() {
        let metrics = LibraryGridLayoutMetrics()
        for width: CGFloat in [100, 320, 390, 768, 1024, 1440] {
            XCTAssertEqual(metrics.columnCount(forWidth: width), 2)
        }
    }

    func testUnavailableWidthDoesNotChangeColumnPolicy() {
        let metrics = LibraryGridLayoutMetrics()
        XCTAssertEqual(metrics.columnCount(forWidth: 0), 2)
        XCTAssertEqual(metrics.columnCount(forWidth: -100), 2)
    }

    func testTileWidthGrowsInsteadOfAddingColumns() {
        let metrics = LibraryGridLayoutMetrics()
        let iPad = metrics.tileWidth(forWidth: 1024, columns: 2)
        let iPhone = metrics.tileWidth(forWidth: 390, columns: 2)
        XCTAssertGreaterThan(iPad, iPhone)
    }

    func testWideTilesUseBothColumnsWithoutUnusedSpace() {
        let metrics = LibraryGridLayoutMetrics()
        let width = metrics.tileWidth(forWidth: 1024, columns: 2)
        XCTAssertEqual(width * 2 + metrics.spacing + metrics.sectionInset * 2, 1024)
    }

    func testTileWidthFillsUsableSpaceAcrossColumns() {
        let metrics = LibraryGridLayoutMetrics()
        let columns = metrics.columnCount(forWidth: 390)
        let width = metrics.tileWidth(forWidth: 390, columns: columns)
        XCTAssertGreaterThan(width, 0)
        XCTAssertEqual(width, 165)
    }

    func testTileWidthNeverNegative() {
        let metrics = LibraryGridLayoutMetrics()
        let width = metrics.tileWidth(forWidth: 10, columns: 5)
        XCTAssertGreaterThanOrEqual(width, 0)
    }
}

#if os(iOS)
@MainActor
final class IOSLibraryCollectionLayoutTests: XCTestCase {
    func testActualLibraryCollectionHasTwoItemsPerRowAcrossResize() async throws {
        let controller = LibraryGridController(metrics: LibraryGridLayoutMetrics())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.loadViewIfNeeded()
        let books = (0..<6).map { index in
            BookEntity(id: "grid-\(index)", title: "Book \(index)", author: "Author",
                       bookmark: Data(), displayFilename: "grid.epub", addedAt: .distantPast)
        }
        controller.apply(model: LibraryGridModel(books: books), animated: false)
        await Task.yield()
        let collection = try XCTUnwrap(controller.collectionView)
        for width: CGFloat in [320, 390, 768, 1024, 320] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
            collection.frame = controller.view.bounds
            collection.collectionViewLayout.invalidateLayout()
            collection.layoutIfNeeded()
            let frames = try (0..<6).map {
                try XCTUnwrap(collection.collectionViewLayout.layoutAttributesForItem(
                    at: IndexPath(item: $0, section: 0))).frame
            }
            for row in 0..<3 {
                let left = frames[row * 2], right = frames[row * 2 + 1]
                XCTAssertEqual(left.minY, right.minY, accuracy: 0.5)
                XCTAssertGreaterThan(right.minX, left.maxX)
                XCTAssertEqual(left.width, right.width, accuracy: 0.5)
                XCTAssertLessThanOrEqual(right.maxX, collection.bounds.width - 19.5)
                if row > 0 { XCTAssertGreaterThan(left.minY, frames[(row - 1) * 2].maxY) }
            }
        }
    }
}
#endif

#if os(macOS)
@MainActor
final class MacLibraryCollectionLayoutTests: XCTestCase, NSCollectionViewDataSource {
    func testTwoColumnsStayInsideViewportWhenWindowResizes() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scrollView = MacLibraryScrollView(frame: try XCTUnwrap(window.contentView).bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        let collectionView = NSCollectionView(frame: scrollView.contentView.bounds)
        collectionView.autoresizingMask = [.width]
        let layout = MacLibraryCollectionLayout()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        scrollView.documentView = collectionView
        window.contentView?.addSubview(scrollView)
        collectionView.reloadData()

        var previousWidth: CGFloat?
        let windowWidths: [CGFloat] = [640, 1024, 481.5, 800]
        for windowWidth in windowWidths {
            window.setContentSize(NSSize(width: windowWidth, height: 480))
            window.contentView?.layoutSubtreeIfNeeded()
            scrollView.tile()
            collectionView.layoutSubtreeIfNeeded()
            // Let pending AppKit layout work finish, then commit the view subtree.
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
            collectionView.layoutSubtreeIfNeeded()
            let viewportWidth = scrollView.contentView.bounds.width
            let frames = try (0..<6).map { index in
                try XCTUnwrap(layout.layoutAttributesForItem(
                    at: IndexPath(item: index, section: 0)
                )).frame
            }
            let expectedWidth = floor((viewportWidth - layout.sectionInset.left
                - layout.sectionInset.right - layout.minimumInteritemSpacing) / 2)
            XCTAssertEqual(collectionView.frame.width, viewportWidth, accuracy: 0.01)
            XCTAssertEqual(layout.itemSize.width, expectedWidth, accuracy: 0.01)
            XCTAssertEqual(frames[0].width, expectedWidth, accuracy: 0.01)
            if let previousWidth {
                XCTAssertNotEqual(frames[0].width, previousWidth)
            }
            previousWidth = frames[0].width

            for row in 0..<3 {
                let left = frames[row * 2]
                let right = frames[row * 2 + 1]
                XCTAssertEqual(left.minY, right.minY, accuracy: 0.01)
                XCTAssertEqual(left.minX, layout.sectionInset.left, accuracy: 0.01)
                XCTAssertEqual(left.width, right.width, accuracy: 0.01)
                XCTAssertGreaterThanOrEqual(right.minX - left.maxX,
                                            layout.minimumInteritemSpacing - 0.01)
                XCTAssertLessThanOrEqual(right.maxX,
                                         viewportWidth - layout.sectionInset.right + 0.01)
                XCTAssertEqual(left.height, left.width * 1.5 + 110, accuracy: 0.01)
                if row > 0 {
                    XCTAssertEqual(left.minY - frames[(row - 1) * 2].maxY,
                                   layout.minimumLineSpacing, accuracy: 0.01)
                }
            }
            XCTAssertLessThanOrEqual(layout.collectionViewContentSize.width,
                                     viewportWidth + 0.01)
        }
    }

    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int { 6 }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = NSCollectionViewItem()
        item.view = NSView()
        return item
    }
}
#endif
