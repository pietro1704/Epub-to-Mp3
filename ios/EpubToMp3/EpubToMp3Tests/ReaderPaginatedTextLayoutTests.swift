import XCTest

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@testable import EpubToMp3

final class ReaderPaginatedTextLayoutTests: XCTestCase {
    @MainActor
    func testMeasuresBeyondTheViewportForALongChapter() {
        let storage = NSTextStorage(string: String(repeating: "A long line of reader text. ", count: 400))
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 120, height: 40))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let height = ReaderPaginatedTextLayout.measuredContentHeight(
            layoutManager: layoutManager,
            textContainer: container,
            verticalInset: 16,
            pageHeight: 40
        )

        XCTAssertGreaterThan(height, 40)
        XCTAssertEqual(container.size.height, .greatestFiniteMagnitude)
    }

    @MainActor
    func testPageOffsetsStartEachSubsequentPageAtALineBoundary() {
        let storage = NSTextStorage(string: String(repeating: "Reader line boundary regression text. ", count: 80))
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 120, height: 40))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        _ = ReaderPaginatedTextLayout.measuredContentHeight(
            layoutManager: layoutManager,
            textContainer: container,
            verticalInset: 0,
            pageHeight: 40
        )
        let offsets = ReaderPaginatedTextLayout.pageOffsets(
            layoutManager: layoutManager,
            textContainer: container,
            verticalInset: 0,
            pageHeight: 40
        )
        var lineStarts: [CGFloat] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: layoutManager.glyphRange(for: container)
        ) { _, usedRect, _, _, _ in
            lineStarts.append(usedRect.minY)
        }
        let maximumScrollOffset = max(
            0,
            ceil(layoutManager.usedRect(for: container).height) - 40
        )

        XCTAssertGreaterThan(offsets.count, 1)
        for offset in offsets.dropFirst() {
            XCTAssertTrue(
                lineStarts.contains(where: { abs($0 - offset) < 0.5 })
                    || abs(offset - maximumScrollOffset) < 0.5,
                "page offset \(offset) must be a line boundary or the reachable final offset"
            )
        }
    }
}
