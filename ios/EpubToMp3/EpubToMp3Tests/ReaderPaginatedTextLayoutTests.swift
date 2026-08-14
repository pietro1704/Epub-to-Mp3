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

    @MainActor
    func testPageOffsetsNeverSplitAFragmentAcrossPages() {
        let font = UIFont(name: "TimesNewRomanPS-ItalicMT", size: 23) ?? .italicSystemFont(ofSize: 23)
        let text = String(repeating: "A café with emoji 😀 and diacritics naïve coöperate. ", count: 180)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 180, height: 220))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let pageHeight: CGFloat = 220
        let offsets = ReaderPaginatedTextLayout.pageOffsets(
            layoutManager: layoutManager,
            textContainer: container,
            verticalInset: 52,
            pageHeight: pageHeight
        )
        let glyphRange = layoutManager.glyphRange(for: container)
        var lineRects: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, _, _ in
            lineRects.append(lineRect)
        }

        XCTAssertFalse(offsets.isEmpty)
        for offset in offsets {
            let viewport = CGRect(x: 0, y: offset, width: container.size.width, height: pageHeight)
            for lineRect in lineRects where lineRect.intersects(viewport) {
                XCTAssertTrue(
                    viewport.contains(lineRect),
                    "page at \(offset) must not display a partial TextKit line \(lineRect)"
                )
            }
        }
    }

    @MainActor
    func testPageOffsetsIncludeTheTextViewTopInsetInScrollCoordinates() {
        let storage = NSTextStorage(string: String(repeating: "Inset-aware pagination must keep every line whole. ", count: 140))
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 180, height: 220))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let topInset: CGFloat = 20
        let bottomInset: CGFloat = 32
        let offsets = ReaderPaginatedTextLayout.pageOffsets(
            layoutManager: layoutManager,
            textContainer: container,
            verticalInset: topInset + bottomInset,
            topInset: topInset,
            pageHeight: 220
        )
        let glyphRange = layoutManager.glyphRange(for: container)
        var lineRects: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, _, _ in
            lineRects.append(lineRect)
        }

        // TextKit line coordinates begin above UITextView's top inset, while
        // UIScrollView offsets begin at the view's content edge. A valid page
        // must therefore translate by the top inset before testing its lines.
        for offset in offsets {
            let visibleTextRect = CGRect(
                x: 0,
                y: offset - topInset,
                width: container.size.width,
                height: 220
            )
            for lineRect in lineRects where lineRect.intersects(visibleTextRect) {
                XCTAssertTrue(
                    visibleTextRect.contains(lineRect),
                    "scroll offset \(offset) exposes a partial line \(lineRect) when UITextView has a top inset"
                )
            }
            let lastLine = lineRects.last(where: { $0.maxY <= visibleTextRect.maxY })
            XCTAssertLessThanOrEqual(
                (lastLine?.maxY ?? 0) + topInset,
                220 - bottomInset + offset,
                "the final visible line must leave the bottom text inset clear"
            )
        }
    }
}
