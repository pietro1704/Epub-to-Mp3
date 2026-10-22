import XCTest
@testable import EpubToMp3
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class ReaderTocFootnotesSearchWiringTests: XCTestCase {
#if os(macOS)
    func testContentsFocusDoesNotNavigateAndUserSelectionKeepsChapterIdentity() throws {
        let harness = try NativeReaderTestHarness(chapters: [
            NativeReaderTestHarness.chapter("First", index: 3, name: "First source"),
            NativeReaderTestHarness.chapter("Second", index: 9, name: "Second source")
        ])
        harness.installTeardown(in: self)
        harness.document.selectedChapter = 1
        let contents = MacReaderContentsPresentation(document: harness.document, composition: harness.composition,
            persistProgress: { harness.persisted += 1 }, showChapter: { harness.showChapter($0) })
        let table = harness.composition.chaptersTable
        table.addTableColumn(NSTableColumn(identifier: .init("chapter")))
        table.dataSource = contents
        table.delegate = contents
        table.reloadData()
        contents.selectCurrentTOCRow()
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertTrue(harness.renderedIndices.isEmpty)
        XCTAssertEqual(harness.persisted, 0)
        let cell = try XCTUnwrap(contents.tableView(table, viewFor: nil, row: 1) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.stringValue, "Second source")
        table.delegate = nil
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        contents.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        XCTAssertEqual(harness.document.selectedChapter, 0)
        XCTAssertEqual(harness.renderedIndices, [0])
        XCTAssertEqual(harness.persisted, 1)
    }
#else
    func testFootnoteSheetDisplaysAuthoredNumbersAndFullText() throws {
        let sheet = ReaderFootnotesSheet(footnotes: [.init(number: "52", text: "Complete note text")])
        sheet.loadViewIfNeeded()
        XCTAssertEqual(sheet.tableView(sheet.tableView, numberOfRowsInSection: 0), 1)
        let cell = sheet.tableView(sheet.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        let content = try XCTUnwrap(cell.contentConfiguration as? UIListContentConfiguration)
        XCTAssertEqual(content.text, "#52")
        XCTAssertEqual(content.secondaryText, "Complete note text")
        XCTAssertEqual(content.secondaryTextProperties.numberOfLines, 0)
    }

    func testSharedContentsDownloadMenuExecutesOnlyTheRequestedAction() throws {
        let snapshot = JobSnapshot(jobId: "remote-reader-download-contract", state: "finished", bookTitle: "Book",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: nil,
            progressPercent: 100, chaptersTotal: 0, chaptersCompleted: 0, chapterProgress: [],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        var downloads = 0
        var cancellations = 0
        var jumps = 0
        let controller = TocScreenController(fulltext: nil, snapshot: snapshot,
            currentChapterIndex: -1, readingChapterIndex: nil,
            onJump: { _ in jumps += 1 }, onDownload: nil,
            onDownloadAll: { downloads += 1 }, onCancelDownloads: { cancellations += 1 }, onClearDownloads: nil)
        controller.loadViewIfNeeded()
        let menu = try XCTUnwrap(controller.navigationItem.leftBarButtonItem?.menu)
        let actions = menu.children.compactMap { $0 as? UIAction }
        let download = try XCTUnwrap(actions.first { $0.title == L10n.string("player.downloadAll") })
        let button = UIButton()
        button.addAction(download, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(jumps, 0)
    }
#endif
}
