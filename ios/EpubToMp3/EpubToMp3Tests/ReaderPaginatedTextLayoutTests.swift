import XCTest

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@testable import EpubToMp3

final class ReaderPaginatedTextLayoutTests: XCTestCase {
    @MainActor
    private func assertNoVisiblePartialFragments(
        in result: ReaderPaginatedTextLayout.Result,
        at offset: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let report = result.clippingReport(at: offset)
        guard !report.clippedFragments.isEmpty else { return }
        let bottomMask = result.bottomOverflowMaskRange(at: offset)
        let topMask = result.topOverflowMaskRange(at: offset)
        let unmaskedFragments = report.clippedFragments.filter { fragment in
            let bottomMasked = bottomMask.map { fragment.contentRect.minY >= $0.lowerBound - 0.5 } ?? false
            let topMasked = topMask.map { fragment.contentRect.maxY <= $0.upperBound + 0.5 } ?? false
            return !bottomMasked && !topMasked
        }
        guard unmaskedFragments.isEmpty else {
            return XCTFail(
                "page at \(offset) exposes a partial fragment outside its overflow masks",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    func testLayoutResultKeepsGlyphBoundsInsideEveryCanonicalPage() {
        let font = UIFont(name: "TimesNewRomanPS-ItalicMT", size: 23) ?? .italicSystemFont(ofSize: 23)
        let storage = NSTextStorage(
            string: String(repeating: "A café with emoji 😀 and descenders gyq. ", count: 180),
            attributes: [.font: font]
        )
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 180, height: 220))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let result = ReaderPaginatedTextLayout.layout(.init(
            layoutManager: layoutManager,
            textContainer: container,
            topInset: 20,
            bottomInset: 32,
            pageHeight: 220
        ))

        XCTAssertGreaterThan(result.contentHeight, 220)
        XCTAssertFalse(result.protectedFragments.isEmpty)
        XCTAssertNil(result.oversizedFragment)
        for offset in result.canonicalPageOffsets {
            assertNoVisiblePartialFragments(in: result, at: offset)
        }
    }

    @MainActor
    func testLayoutResultReportsAnOversizedProtectedFragment() {
        let storage = NSTextStorage(
            string: "Oversized accessibility line",
            attributes: [.font: UIFont.systemFont(ofSize: 160)]
        )
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 180, height: 120))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let result = ReaderPaginatedTextLayout.layout(.init(
            layoutManager: layoutManager,
            textContainer: container,
            topInset: 16,
            bottomInset: 24,
            pageHeight: 120
        ))

        XCTAssertNotNil(result.oversizedFragment)
        XCTAssertTrue(result.requiresScrollingFallback)
    }

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
        let result = ReaderPaginatedTextLayout.layout(.init(
            layoutManager: layoutManager,
            textContainer: container,
            topInset: 0,
            bottomInset: 52,
            pageHeight: pageHeight
        ))

        XCTAssertFalse(result.canonicalPageOffsets.isEmpty)
        for offset in result.canonicalPageOffsets {
            assertNoVisiblePartialFragments(in: result, at: offset)
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
        let result = ReaderPaginatedTextLayout.layout(.init(
            layoutManager: layoutManager,
            textContainer: container,
            topInset: topInset,
            bottomInset: bottomInset,
            pageHeight: 220
        ))

        // `contentRect` includes UITextView's top inset, therefore offsets
        // are in scroll-content coordinates and must keep the entire
        // protected glyph fragment above the reserved bottom inset.
        for offset in result.canonicalPageOffsets {
            assertNoVisiblePartialFragments(in: result, at: offset)
        }
    }

    @MainActor
    func testOversizedFragmentIsReportedForTheReaderScrollingFallback() {
        let storage = NSTextStorage(string: "Oversized")
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 180, height: 40))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let result = ReaderPaginatedTextLayout.layout(.init(
            layoutManager: layoutManager,
            textContainer: container,
            topInset: 0,
            bottomInset: 0,
            pageHeight: 1
        ))

        XCTAssertNotNil(result.oversizedFragment)
    }

    @MainActor
    func testCJKAndInlineAttachmentKeepProtectedFragmentsWhole() {
        let attachment = NSTextAttachment()
        attachment.bounds = CGRect(x: 0, y: -4, width: 18, height: 22)
        let text = NSMutableAttributedString(
            string: String(repeating: "日本語と中文的段落。", count: 80),
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        text.insert(NSAttributedString(attachment: attachment), at: 24)
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 180, height: 220))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let result = ReaderPaginatedTextLayout.layout(.init(
            layoutManager: layoutManager,
            textContainer: container,
            topInset: 16,
            bottomInset: 24,
            pageHeight: 220
        ))

        XCTAssertFalse(result.requiresScrollingFallback)
        XCTAssertTrue(result.protectedFragments.contains {
            $0.glyphRange.location <= 24 && NSMaxRange($0.glyphRange) > 24
        })
        for offset in result.canonicalPageOffsets {
            assertNoVisiblePartialFragments(in: result, at: offset)
        }
    }
}
