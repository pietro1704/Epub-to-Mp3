#if os(macOS)
import AppKit
import PDFKit
import XCTest
@testable import EpubToMp3

/// The Mac contents list of a PDF shows the same narration chapters as iOS and jumps to them.
@MainActor
final class MacReaderPDFContentsTests: XCTestCase {
    func testPDFWithAnOutlineListsItsChaptersAndJumpsToTheSelectedOne() async throws {
        let titles = ["The lighthouse", "The crossing", "The harbor"]
        let source = try PdfFixture.createMultiPage(pages: titles.map {
            (heading: $0, body: "The boat keeps following the coast on this page of the synthetic book.")
        })
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(data: Data(contentsOf: source)))
        let root = PDFOutline()
        for (index, title) in titles.enumerated() {
            let item = PDFOutline()
            item.label = title
            item.destination = PDFDestination(page: try XCTUnwrap(document.page(at: index)), at: NSPoint(x: 0, y: 792))
            root.insertChild(item, at: index)
        }
        document.outlineRoot = root
        XCTAssertTrue(document.write(to: source))

        try await assertContents(of: source, list: titles)
    }

    func testPDFWithoutAnOutlineListsTheAutomaticChapters() async throws {
        let source = try PdfFixture.createMultiPage(pages: [
            (heading: "Preface", body: "A long enough preface from the author of this synthetic book."),
            (heading: "Chapter 1", body: "The first chapter starts here with a reasonably long line of text."),
            (heading: "Chapter 2", body: "The second chapter starts here with a reasonably long line of text."),
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertNil(try XCTUnwrap(PDFDocument(url: source)).outlineRoot)

        try await assertContents(of: source, list: ["Front matter", "Chapter 1", "Chapter 2"])
    }

    private func assertContents(of source: URL, list expected: [String]) async throws {
        let harness = try NativeReaderTestHarness(chapters: [])
        harness.installTeardown(in: self)
        let composition = harness.composition
        let root = harness.controller.view
        let size = NSSize(width: 900, height: 500)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = harness.controller
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        defer {
            composition.tocPopover.close()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        root.layoutSubtreeIfNeeded()
        harness.document.currentBookId = harness.id
        // The app has no parsed book text for a PDF.
        harness.document.fulltext = nil
        let normalized = await harness.text.showPDF(source)
        XCTAssertEqual(normalized, false)
        // PDFKit keeps laying out after the document is assigned.
        try await Task.sleep(nanoseconds: 700_000_000)
        let pdf = try XCTUnwrap(composition.contentScrollView.documentView as? PDFView)
        let contents = MacReaderContentsPresentation(
            document: harness.document, composition: composition, persistProgress: {},
            showChapter: { XCTFail("a PDF row must not render book text: \($0)") })
        let button = NSButton(frame: NSRect(x: 10, y: 10, width: 40, height: 24))
        root.addSubview(button)

        contents.showTOC(button)

        XCTAssertTrue(composition.tocPopover.isShown, "the contents button must open the list")
        let table = composition.chaptersTable
        let titles = (0..<contents.numberOfRows(in: table)).map {
            (contents.tableView(table, viewFor: nil, row: $0) as? NSTableCellView)?.textField?.stringValue ?? ""
        }
        XCTAssertEqual(titles, expected)
        XCTAssertEqual(table.selectedRow, 0, "the open chapter is highlighted")
        guard titles.count == expected.count else { return }

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        let current = try XCTUnwrap(pdf.currentPage)
        XCTAssertEqual(pdf.document?.index(for: current), 1, "the row opens its chapter's page")
    }
}
#endif
