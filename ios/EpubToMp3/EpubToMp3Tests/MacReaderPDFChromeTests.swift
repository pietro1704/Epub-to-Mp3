#if os(macOS)
import AppKit
import PDFKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderPDFChromeTests: XCTestCase {
    func testFirstHeadingClearsChromeAndTogglesPreservePDFOffset() async throws {
        try await assertFirstHeadingClearsChrome(hostedInWindow: false)
    }

    /// The app always shows the reader in a window, where PDFKit lays out for a real screen.
    func testFirstHeadingClearsChromeWhenTheReaderIsInAWindow() async throws {
        try await assertFirstHeadingClearsChrome(hostedInWindow: true)
    }

    private func assertFirstHeadingClearsChrome(hostedInWindow: Bool) async throws {
        let harness = try NativeReaderTestHarness(chapters: [])
        harness.installTeardown(in: self)
        let heading = "Opening line near the top edge"
        let source = try PdfFixture.createMultiPage(pages: [
            (heading: heading, body: "First page body."),
            (heading: "Second page", body: "Second page body.")
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let fixtureData = try Data(contentsOf: source)
        let fixture = try XCTUnwrap(PDFDocument(data: fixtureData))
        let first = try XCTUnwrap(fixture.page(at: 0))
        let headingBounds = try bounds(of: heading, in: first)
        var crop = first.bounds(for: .cropBox)
        crop.size.height = headingBounds.maxY + 4 - crop.minY
        first.setBounds(crop, for: .cropBox)
        XCTAssertTrue(fixture.write(to: source))

        let composition = harness.composition
        let root = harness.controller.view
        var window: NSWindow?
        if hostedInWindow {
            let host = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.contentViewController = harness.controller
            host.setContentSize(root.frame.size)
            host.makeKeyAndOrderFront(nil)
            window = host
        }
        defer { window?.orderOut(nil); window?.contentViewController = nil; window?.close() }
        root.layoutSubtreeIfNeeded()
        let normalized = await harness.text.showPDF(source)
        XCTAssertEqual(normalized, false)
        // PDFKit keeps laying out after the document is assigned.
        if hostedInWindow { try await Task.sleep(nanoseconds: 700_000_000) }
        let pdf = try XCTUnwrap(composition.contentScrollView.documentView as? PDFView)
        pdf.layoutDocumentView()
        let page = try XCTUnwrap(pdf.document?.page(at: 0))
        XCTAssertTrue(pdf.currentPage === page)
        let chrome = try XCTUnwrap(root.subviews.compactMap { $0 as? NSVisualEffectView }
            .first { $0.material == .headerView })
        XCTAssertFalse(chrome.isHidden)
        let openingLine = pdf.convert(try bounds(of: heading, in: page), from: page)
        XCTAssertTrue(pdf.visibleRect.contains(openingLine))
        let openingLineInReader = pdf.convert(openingLine, to: root)
        if root.isFlipped {
            XCTAssertGreaterThanOrEqual(openingLineInReader.minY, chrome.frame.maxY)
        } else {
            XCTAssertLessThanOrEqual(openingLineInReader.maxY, chrome.frame.minY)
        }

        let scroll = try XCTUnwrap(pdf.documentView?.enclosingScrollView)
        XCTAssertTrue(scroll.isDescendant(of: pdf))
        let clip = scroll.contentView
        let openingOffset = clip.bounds.origin
        let pdfFrame = pdf.frame
        let maximumY = clip.documentRect.maxY - clip.bounds.height
        let middleY = (clip.documentRect.minY + maximumY) / 2
        clip.scroll(to: NSPoint(x: openingOffset.x, y: middleY))
        scroll.reflectScrolledClipView(clip)
        let readingOffset = clip.bounds.origin
        XCTAssertNotEqual(readingOffset, openingOffset)
        for hidden in [true, false] {
            composition.setChromeHidden(hidden)
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(chrome.isHidden, hidden)
            XCTAssertEqual(pdf.frame, pdfFrame)
            XCTAssertEqual(clip.bounds.origin, readingOffset)
        }
    }

    private func bounds(of heading: String, in page: PDFPage) throws -> NSRect {
        let pageText = try XCTUnwrap(page.string) as NSString
        let headingRange = pageText.range(of: heading)
        guard headingRange.location != NSNotFound else { throw CocoaError(.fileReadCorruptFile) }
        let selection = try XCTUnwrap(page.selection(for: headingRange))
        let bounds = selection.bounds(for: page)
        XCTAssertFalse(bounds.isEmpty)
        return bounds
    }
}
#endif
