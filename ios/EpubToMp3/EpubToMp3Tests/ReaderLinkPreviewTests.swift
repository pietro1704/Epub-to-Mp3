#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderLinkPreviewTests: XCTestCase {
    private func chapters() -> [EbookFulltext.Chapter] {
        [
            .init(index: 3, name: "Main", sourcePath: "text/main.xhtml", text: "Current passage.",
                html: "<p>Current passage.</p>", css: nil, charCount: nil, segments: nil),
            .init(index: 9, name: "Notes", sourcePath: "text/notes.xhtml", text: "Destination note.",
                html: "<p>Earlier.</p><p id='n'>Destination <em>note</em>.</p>", css: nil, charCount: nil, segments: nil)
        ]
    }

    func testPreviewScrollsAndDoesNotNavigateUntilExplicitGoAction() throws {
        let harness = try NativeReaderTestHarness(chapters: chapters())
        harness.installTeardown(in: self)
        harness.showChapter(0)
        let offset = harness.composition.scrollView.contentOffset
        var presented: UIViewController?
        let links = ReaderLinkPresentation(document: harness.document, composition: harness.composition, settings: harness.settings,
            persist: { harness.persisted += 1 }, showChapter: { harness.showChapter($0) },
            present: { presented = $0 }, isCurrentBook: { true })
        let url = try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "notes.xhtml#n"))
        XCTAssertFalse(links.handle(url, linkText: "1"))
        let preview = try XCTUnwrap((presented as? UINavigationController)?.viewControllers.first as? ReaderLinkPreviewController)
        preview.loadViewIfNeeded()
        XCTAssertTrue(preview.textView.isScrollEnabled)
        XCTAssertTrue(preview.textView.text.contains("Destination note."))
        XCTAssertEqual(harness.document.selectedChapter, 0)
        XCTAssertEqual(harness.composition.scrollView.contentOffset, offset)
        XCTAssertEqual(harness.persisted, 0)
        preview.goToPosition()
        XCTAssertEqual(harness.document.selectedChapter, 1)
        XCTAssertTrue(harness.displayed.string.contains("Destination note."))
        XCTAssertEqual(harness.persisted, 1)
        preview.goToPosition()
        XCTAssertEqual(harness.persisted, 1)
    }

    func testClosingOrReplacingBookCannotCommitThePreviewDestination() throws {
        let harness = try NativeReaderTestHarness(chapters: chapters())
        harness.installTeardown(in: self)
        harness.showChapter(0)
        var current = true
        var presented: UIViewController?
        let links = ReaderLinkPresentation(document: harness.document, composition: harness.composition, settings: harness.settings,
            persist: { harness.persisted += 1 }, showChapter: { harness.showChapter($0) },
            present: { presented = $0 }, isCurrentBook: { current })
        XCTAssertFalse(links.handle(try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "notes.xhtml#n")), linkText: "1"))
        let preview = try XCTUnwrap((presented as? UINavigationController)?.viewControllers.first as? ReaderLinkPreviewController)
        current = false
        preview.goToPosition()
        XCTAssertEqual(harness.document.selectedChapter, 0)
        XCTAssertEqual(harness.renderedIndices, [0])
        XCTAssertEqual(harness.persisted, 0)
    }

    func testMissingTargetReportsFeedbackWithoutChangingTheBook() throws {
        let harness = try NativeReaderTestHarness(chapters: chapters())
        harness.installTeardown(in: self)
        harness.showChapter(0)
        var presented: UIViewController?
        let links = ReaderLinkPresentation(document: harness.document, composition: harness.composition, settings: harness.settings,
            persist: { harness.persisted += 1 }, showChapter: { harness.showChapter($0) },
            present: { presented = $0 }, isCurrentBook: { true })
        XCTAssertFalse(links.handle(try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "notes.xhtml#missing")), linkText: "Missing"))
        XCTAssertTrue(presented is UIAlertController)
        XCTAssertEqual(harness.document.selectedChapter, 0)
        XCTAssertEqual(harness.persisted, 0)
        XCTAssertTrue(links.handle(try XCTUnwrap(URL(string: "https://example.com/")), linkText: "External"))
    }

    func testPreparedOnlyChapterKeepsItsOriginalOrdinalWhenPreviewingANote() throws {
        let harness = try NativeReaderTestHarness(chapters: [])
        harness.installTeardown(in: self)
        let chapter = chapters()[1]
        harness.document.fulltext = nil
        harness.document.selectedChapter = 7
        harness.document.activePreparedChapter = .init(bookID: harness.book.id, title: "Book", author: nil,
            chapterOrdinal: 7, chapterCount: 10, chapter: chapter, toc: nil, catalogChapters: nil)
        harness.showChapter(7)
        var presented: UIViewController?
        let links = ReaderLinkPresentation(document: harness.document, composition: harness.composition, settings: harness.settings,
            persist: { harness.persisted += 1 }, showChapter: { harness.showChapter($0) },
            present: { presented = $0 }, isCurrentBook: { true })
        XCTAssertFalse(links.handle(try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "#n")), linkText: "1"))
        let preview = try XCTUnwrap((presented as? UINavigationController)?.viewControllers.first as? ReaderLinkPreviewController)
        preview.goToPosition()
        XCTAssertEqual(harness.document.selectedChapter, 7)
        XCTAssertEqual(harness.renderedIndices, [7, 7])
        XCTAssertEqual(harness.persisted, 1)
    }

    func testDismissedPreviewRejectsALateGoAction() {
        var navigations = 0
        let preview = ReaderLinkPreviewController(title: "Note", body: NSAttributedString(string: "Body"),
            navigate: { navigations += 1 })
        preview.loadViewIfNeeded()
        preview.close()
        preview.goToPosition()
        XCTAssertEqual(navigations, 0)
    }

    func testLongFootnoteRetainsCompleteTextAndOffersNoInventedDestination() {
        let body = String(repeating: "Long note text. ", count: 500)
        let preview = ReaderLinkPreviewController(title: "Note", body: NSAttributedString(string: body), navigate: nil)
        preview.loadViewIfNeeded()
        XCTAssertTrue(preview.textView.isScrollEnabled)
        XCTAssertEqual(preview.textView.text, body)
        XCTAssertNil(preview.navigationItem.rightBarButtonItem)
        XCTAssertFalse(preview.textView(preview.textView, shouldInteractWith: URL(string: "epub-link://open")!,
            in: NSRange(location: 0, length: 1), interaction: .invokeDefaultAction))
    }
}
#endif
