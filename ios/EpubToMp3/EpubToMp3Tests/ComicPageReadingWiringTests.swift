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

    func testMacReaderListeningIsUnavailableForComicsAndKeptForText() throws {
        let suite = "comic-listening-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let readingKey = ReaderSessionState.currentlyReadingBookIDKey
        let savedReading = UserDefaults.standard.object(forKey: readingKey)
        let comic = BookEntity(id: "comic-capability", title: "Comic", bookmark: Data([1]), displayFilename: "comic.cbz", addedAt: .distantPast, fileType: .cbz)
        let text = BookEntity(id: "text-capability", title: "Text", bookmark: Data([1]), displayFilename: "book.epub", addedAt: .distantPast, fileType: .epub)
        defaults.set(try JSONEncoder().encode([comic, text]), forKey: "library")
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard)
        defer {
            player.stop()
            if let savedReading { UserDefaults.standard.set(savedReading, forKey: readingKey) }
            else { UserDefaults.standard.removeObject(forKey: readingKey) }
            defaults.removePersistentDomain(forName: suite)
        }
        var executorCalls = 0
        let session = MacReaderPlaybackSession(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), player: player,
            playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, _, _, _, _, _, _, _, _ in
                executorCalls += 1
                throw CancellationError()
            })
        UserDefaults.standard.set(comic.id, forKey: readingKey)
        session.start(owner: self)
        XCTAssertNil(session.localPlaybackGeneration, "Comics have no text to narrate")
        XCTAssertNil(player.snapshot)
        UserDefaults.standard.set(text.id, forKey: readingKey)
        session.start(owner: self)
        XCTAssertEqual(session.localPlaybackBookID, text.id, "Text books keep the reader Listen action")
        // Retire the pending generation so the unreadable fixture cannot present an alert.
        session.cancel(stopPlayer: false)
        XCTAssertEqual(executorCalls, 0)
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
