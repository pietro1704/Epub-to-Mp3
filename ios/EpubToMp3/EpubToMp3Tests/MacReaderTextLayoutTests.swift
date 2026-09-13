#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderTextLayoutTests: XCTestCase {
    func testFitsTextIntoViewportWhenDocumentViewStartsAtZero() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = MacReaderTextView(frame: .zero, textContainer: nil)
        textView.string = "Visible reader text. " + String(repeating: "More text. ", count: 400)
        scrollView.documentView = textView

        MacReaderTextLayout.fit(textView, in: scrollView)

        XCTAssertEqual(textView.frame.width, scrollView.contentView.bounds.width)
        XCTAssertGreaterThan(textView.frame.height, 0)
        XCTAssertNotNil(textView.textContainer)
        XCTAssertNotNil(textView.textStorage)
        XCTAssertGreaterThan(textView.layoutManager!.usedRect(for: textView.textContainer!).height, 0)
    }

    func testReplacingLongChapterCommitsStableHeightBeforeScrolling() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = MacReaderTextView(frame: .zero, textContainer: nil)
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 32, height: 24)
        scrollView.documentView = textView
        textView.string = String(repeating: "A complete line of current chapter text.\n", count: 240)
        textView.font = .systemFont(ofSize: 18)
        MacReaderTextLayout.fit(textView, in: scrollView)

        textView.string = String(repeating: "A complete line of previous chapter text.\n", count: 200)
        textView.font = .systemFont(ofSize: 18)
        MacReaderTextLayout.fit(textView, in: scrollView)

        let container = try XCTUnwrap(textView.textContainer)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let firstHeight = textView.frame.height
        let firstUsedHeight = layoutManager.usedRect(for: container).height
        let firstContainerWidth = container.containerSize.width
        let expectedWidth = scrollView.contentView.bounds.width - textView.textContainerInset.width * 2
        XCTAssertEqual(firstContainerWidth, expectedWidth, accuracy: 0.5)
        XCTAssertGreaterThan(firstHeight, scrollView.contentView.bounds.height * 2)
        let end = firstHeight - scrollView.contentView.bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: end))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        textView.layoutSubtreeIfNeeded()
        MacReaderTextLayout.fit(textView, in: scrollView)

        XCTAssertEqual(container.containerSize.width, firstContainerWidth, accuracy: 0.5)
        XCTAssertEqual(layoutManager.usedRect(for: container).height, firstUsedHeight, accuracy: 0.5)
        XCTAssertEqual(textView.frame.height, firstHeight, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y,
                       textView.frame.height - scrollView.contentView.bounds.height, accuracy: 0.5)
    }
}
#endif
