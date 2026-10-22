import XCTest
import UniformTypeIdentifiers
@testable import EpubToMp3
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class ComicPageReadingWiringTests: XCTestCase {
    func testNativeChapterSurfaceMountsComicImageAndReturnsToReadableText() throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jBqkAAAAASUVORK5CYII="
        let comic = EbookFulltext.Chapter(index: 1, name: "Page", text: "", html: nil, css: nil,
            charCount: 0, segments: nil, resources: [.init(href: "page.png", mediaType: "image/png", dataBase64: png)], contentKind: "images")
        let harness = try NativeReaderTestHarness(chapters: [comic, NativeReaderTestHarness.chapter("Readable text", index: 2)])
        harness.installTeardown(in: self)
        harness.showChapter(0)
        XCTAssertNotNil(harness.composition.comicPageImageView.image)
#if os(macOS)
        XCTAssertTrue(harness.composition.contentScrollView.documentView === harness.composition.comicPageImageView)
#else
        XCTAssertFalse(harness.composition.comicPageImageView.isHidden)
        XCTAssertTrue(harness.composition.textView.isHidden)
#endif
        harness.showChapter(1)
#if os(macOS)
        XCTAssertTrue(harness.composition.contentScrollView.documentView === harness.composition.textView)
#else
        XCTAssertTrue(harness.composition.comicPageImageView.isHidden)
        XCTAssertFalse(harness.composition.textView.isHidden)
#endif
        XCTAssertEqual(harness.displayed.string, "Readable text")
    }

#if os(macOS)
    func testUnavailableComicImageClearsPriorPageInsteadOfReusingIt() throws {
        let chapter = EbookFulltext.Chapter(index: 1, name: "Unavailable page", text: "", html: nil, css: nil,
            charCount: 0, segments: nil, resources: nil, contentKind: "images")
        let harness = try NativeReaderTestHarness(chapters: [chapter])
        harness.installTeardown(in: self)
        harness.composition.comicPageImageView.image = NSImage(size: NSSize(width: 1, height: 1))
        harness.showChapter(0)
        XCTAssertNil(harness.composition.comicPageImageView.image)
        XCTAssertTrue(harness.composition.contentScrollView.documentView === harness.composition.comicPageImageView)
    }

    func testBookDetailDisablesComicListeningAndReenablesTextListening() {
        let content = MacBookDetailContent()
        let comic = BookEntity(id: "comic-capability", title: "Comic", bookmark: Data(), displayFilename: "comic.cbz", addedAt: .distantPast, fileType: .cbz)
        content.render(book: comic, localConversionProgress: nil)
        XCTAssertFalse(content.listenButton.isEnabled)
        XCTAssertEqual(content.listenButton.title, L10n.string("bookDetail.listenUnavailableComic"))
        let text = BookEntity(id: "text-capability", title: "Text", bookmark: Data(), displayFilename: "book.epub", addedAt: .distantPast, fileType: .epub)
        content.render(book: text, localConversionProgress: nil)
        XCTAssertTrue(content.listenButton.isEnabled)
        XCTAssertEqual(content.listenButton.title, L10n.string("bookDetail.listenStart"))
    }
#endif

    func testSharedImportTypeListAcceptsSupportedDocumentsAndExpandedEpubFolders() {
        for ext in ["epub", "pdf", "fb2", "docx", "cbz", "cbr", "mobi", "azw", "azw3", "prc"] {
            if let type = UTType(filenameExtension: ext) {
                XCTAssertTrue(SupportedImportTypes.all.contains(type), "Missing picker type: \(ext)")
            }
        }
        XCTAssertTrue(SupportedImportTypes.all.contains(.folder))
    }

    func testLegacyAndTextPayloadsAreNotMistakenForComicPages() {
        for kind in [nil, "text"] as [String?] {
            let chapter = EbookFulltext.Chapter(index: 1, name: "Text", text: "hello", html: nil,
                css: nil, charCount: 5, segments: nil, contentKind: kind)
            XCTAssertFalse(chapter.isImageOnly)
        }
    }
}
