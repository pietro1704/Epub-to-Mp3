//
//  LibraryGridLayoutMetricsTests.swift
//  EpubToMp3Tests
//
//  Pure column-math coverage for the library grid layout helpers shared by
//  the remaining grid renderers.
//

import XCTest
@testable import EpubToMp3

final class LibraryGridLayoutMetricsTests: XCTestCase {

    func testPhoneTileReservesSpaceForCoverAndMetadata() {
        let metrics = LibraryGridLayoutMetrics()
        let columns = metrics.columnCount(forWidth: 390)
        let height = metrics.tileWidth(forWidth: 390, columns: columns) * 1.5 + 70

        XCTAssertGreaterThan(height, 600)
    }

    func testColumnCountPacksAsManyMinWidthTilesAsFit() {
        let metrics = LibraryGridLayoutMetrics()
        // 390pt iPhone width minus 2*20 inset = 350 usable.
        // (350 + 20) / (160 + 20) = 2.05 -> 2 columns.
        XCTAssertEqual(metrics.columnCount(forWidth: 390), 2)
    }

    func testColumnCountNeverGoesBelowOne() {
        let metrics = LibraryGridLayoutMetrics()
        XCTAssertEqual(metrics.columnCount(forWidth: 0), 1)
        XCTAssertEqual(metrics.columnCount(forWidth: -100), 1)
    }

    func testColumnCountGrowsOnWiderScreens() {
        let metrics = LibraryGridLayoutMetrics()
        let iPad = metrics.columnCount(forWidth: 1024)
        let iPhone = metrics.columnCount(forWidth: 390)
        XCTAssertGreaterThan(iPad, iPhone)
    }

    func testTileWidthClampedToMax() {
        let metrics = LibraryGridLayoutMetrics()
        // A single column on a very wide surface would exceed maxTileWidth.
        let width = metrics.tileWidth(forWidth: 1024, columns: 1)
        XCTAssertEqual(width, metrics.maxTileWidth)
    }

    func testTileWidthFillsUsableSpaceAcrossColumns() {
        let metrics = LibraryGridLayoutMetrics()
        let columns = metrics.columnCount(forWidth: 390)
        let width = metrics.tileWidth(forWidth: 390, columns: columns)
        XCTAssertGreaterThan(width, 0)
        XCTAssertLessThanOrEqual(width, metrics.maxTileWidth)
    }

    func testTileWidthNeverNegative() {
        let metrics = LibraryGridLayoutMetrics()
        let width = metrics.tileWidth(forWidth: 10, columns: 5)
        XCTAssertGreaterThanOrEqual(width, 0)
    }
}
