//
//  LibraryCoverThumbnailCacheTests.swift
//  EpubToMp3Tests
//
//  Regression coverage for the library grid's off-main-thread cover
//  downsampling (LibraryCollectionView.swift). BookGridCell.configure used
//  to decode full-resolution UIImage(data:) synchronously on the main
//  thread inside CellRegistration; LibraryCoverThumbnailCache.decode
//  produces a bounded-size thumbnail instead, safe to call off-main.
//

#if canImport(UIKit)
import XCTest
import UIKit
@testable import EpubToMp3

final class LibraryCoverThumbnailCacheTests: XCTestCase {

    /// A synthetic square PNG well above the thumbnail cap, so a passing
    /// test proves real downsampling happened (not a pass-through).
    private func makeSourcePNGData(sidePixels: CGFloat = 1200) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: sidePixels, height: sidePixels))
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: sidePixels, height: sidePixels))
        }
        return image.pngData()!
    }

    func testDecodeProducesImageAtOrBelowMaxPixelSize() {
        let data = makeSourcePNGData()
        let image = LibraryCoverThumbnailCache.decode(data, bookID: "book-\(UUID())")
        let decoded = try? XCTUnwrap(image)
        XCTAssertNotNil(decoded)
        guard let cg = decoded?.cgImage else { return XCTFail("expected a decoded CGImage") }
        XCTAssertLessThanOrEqual(CGFloat(cg.width), LibraryCoverThumbnailCache.maxPixelSize)
        XCTAssertLessThanOrEqual(CGFloat(cg.height), LibraryCoverThumbnailCache.maxPixelSize)
    }

    func testDecodeIsSmallerThanSourceResolution() {
        let sourceSide: CGFloat = 1200
        let data = makeSourcePNGData(sidePixels: sourceSide)
        let image = LibraryCoverThumbnailCache.decode(data, bookID: "book-\(UUID())")
        guard let cg = image?.cgImage else { return XCTFail("expected a decoded CGImage") }
        XCTAssertLessThan(CGFloat(cg.width), sourceSide)
    }

    func testDecodeCachesUnderBookID() {
        let bookID = "book-\(UUID())"
        XCTAssertNil(LibraryCoverThumbnailCache.cached(for: bookID))
        let data = makeSourcePNGData()
        let decoded = LibraryCoverThumbnailCache.decode(data, bookID: bookID)
        XCTAssertNotNil(decoded)
        XCTAssertNotNil(LibraryCoverThumbnailCache.cached(for: bookID))
    }

    func testCachedReturnsNilForUnknownBook() {
        XCTAssertNil(LibraryCoverThumbnailCache.cached(for: "never-decoded-\(UUID())"))
    }

    func testDecodeReturnsNilForGarbageData() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertNil(LibraryCoverThumbnailCache.decode(garbage, bookID: "book-\(UUID())"))
    }
}
#endif
