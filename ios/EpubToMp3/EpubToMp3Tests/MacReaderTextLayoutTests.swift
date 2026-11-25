#if os(macOS)
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

    /// MAC-READER-IMAGE-FIT (mac-image-not-fit.png): an inline EPUB figure kept
    /// its intrinsic size on macOS, wider and taller than the page, and was
    /// clipped. It must fit the visible text area in both dimensions.
    func testInlineFigureFitsTheVisiblePage() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let textView = MacReaderTextView(frame: .zero, textContainer: nil)
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 32, height: 24)
        scrollView.documentView = textView
        let figure = NSImage(size: NSSize(width: 3000, height: 2000), flipped: false) { rect in
            NSColor.systemOrange.setFill(); rect.fill()
            NSColor.black.setStroke(); NSBezierPath(rect: rect.insetBy(dx: 40, dy: 40)).stroke()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = figure
        let chapter = NSMutableAttributedString(string: "Before the figure.\n",
                                                attributes: [.font: NSFont.systemFont(ofSize: 18)])
        chapter.append(NSAttributedString(attachment: attachment))
        chapter.append(NSAttributedString(string: "\nFigure 1.1: caption after the figure.",
                                          attributes: [.font: NSFont.systemFont(ofSize: 18)]))
        textView.textStorage?.setAttributedString(chapter)

        MacReaderTextLayout.fit(textView, in: scrollView)

        let container = try XCTUnwrap(textView.textContainer)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let usableWidth = container.containerSize.width - container.lineFragmentPadding * 2
        let usableHeight = scrollView.contentView.bounds.height - textView.textContainerInset.height * 2
        let index = (textView.string as NSString).range(of: "\u{FFFC}").location
        XCTAssertNotEqual(index, NSNotFound)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                              actualCharacterRange: nil)
        let drawn = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        XCTAssertLessThanOrEqual(attachment.bounds.width, usableWidth + 0.5)
        XCTAssertLessThanOrEqual(attachment.bounds.height, usableHeight + 0.5)
        XCTAssertGreaterThan(attachment.bounds.width, 0)
        XCTAssertEqual(attachment.bounds.width / attachment.bounds.height, 1.5, accuracy: 0.01,
                       "The figure keeps its aspect ratio")
        XCTAssertLessThanOrEqual(drawn.maxX, container.containerSize.width + 0.5,
                                 "The figure must not extend past the visible page")

        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        scrollView.layoutSubtreeIfNeeded()
        if let bitmap = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds) {
            scrollView.cacheDisplay(in: scrollView.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let shot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                shot.name = "mac-reader-inline-figure-fit"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
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
