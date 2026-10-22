import ImageIO
import XCTest
@testable import EpubToMp3

final class WidgetSnapshotTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "WidgetSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func seedBooks(_ defaults: UserDefaults) throws {
        let books: [[String: Any]] = (0..<8).map { index in
            ["id": "book-\(index)", "title": "Title \(index)", "author": "Author \(index)",
             "lastOpenedAt": Double(index), "lastChapterIndex": index]
        }
        defaults.set(try JSONSerialization.data(withJSONObject: books), forKey: "library.books.v1")
    }

    func testNowPlayingMatchesBookIdentityAndRetainsMetadata() throws {
        try withDefaults { defaults in
            try seedBooks(defaults)
            defaults.set("book-2", forKey: "currentlyPlayingBookId")
            defaults.set("Narration author", forKey: "widget.nowPlayingAuthor")
            defaults.set("Chapter label", forKey: "widget.nowPlayingChapterName")
            defaults.set(0.25, forKey: "widget.nowPlayingProgress")
            defaults.set(true, forKey: "widget.nowPlayingIsPlaying")
            defaults.set(30, forKey: "widget.nowPlayingChapterRemainingSeconds")
            defaults.set(90, forKey: "widget.nowPlayingBookRemainingSeconds")
            defaults.set(8, forKey: "widget.nowPlayingTotalChapters")
            let entry = NowPlayingProvider().loadNowPlaying(defaults: defaults)
            XCTAssertEqual(entry.bookId, "book-2")
            XCTAssertEqual(entry.title, "Title 2")
            XCTAssertEqual(entry.author, "Narration author")
            XCTAssertEqual(entry.chapterIndex, 2)
            XCTAssertEqual(entry.chapterName, "Chapter label")
            XCTAssertEqual(entry.progress, 0.25)
            XCTAssertTrue(entry.isPlaying)
            XCTAssertEqual(entry.chapterRemainingSeconds, 30)
            XCTAssertEqual(entry.bookRemainingSeconds, 90)
            XCTAssertEqual(entry.totalChapters, 8)
            defaults.set("missing", forKey: "currentlyPlayingBookId")
            XCTAssertNil(NowPlayingProvider().loadNowPlaying(defaults: defaults).bookId)
        }
    }

    func testContinueReadingUsesExplicitIdentityAndDoesNotBorrowOtherBooksTiming() throws {
        try withDefaults { defaults in
            try seedBooks(defaults)
            let provider = ContinueReadingProvider()
            XCTAssertEqual(provider.loadContinueReading(defaults: defaults).bookId, "book-7")
            defaults.set("book-2", forKey: "widget.lastReadBookId")
            defaults.set(4, forKey: "widget.lastReadChapterIndex")
            defaults.set(10, forKey: "widget.lastReadTotalChapters")
            defaults.set("Capítulo cinco", forKey: "widget.lastReadChapterLabel")
            defaults.set("book-7", forKey: "currentlyPlayingBookId")
            defaults.set(90, forKey: "widget.nowPlayingBookRemainingSeconds")
            let entry = provider.loadContinueReading(defaults: defaults)
            XCTAssertEqual(entry.bookId, "book-2")
            XCTAssertEqual(entry.chapterIndex, 4)
            XCTAssertEqual(entry.chapterLabel, "Capítulo cinco")
            XCTAssertEqual(entry.progressPercent, 50)
            XCTAssertEqual(entry.bookRemainingSeconds, 0)
            defaults.set("missing", forKey: "widget.lastReadBookId")
            XCTAssertNil(provider.loadContinueReading(defaults: defaults).bookId)
        }
    }

    func testLibrarySortsAndBoundsEntriesAndRecoversFromMalformedPayload() throws {
        try withDefaults { defaults in
            try seedBooks(defaults)
            let provider = LibraryProvider()
            XCTAssertEqual(provider.loadLibrary(defaults: defaults).books.map(\.id),
                           ["book-7", "book-6", "book-5", "book-4", "book-3", "book-2"])
            defaults.set(Data("malformed".utf8), forKey: "library.books.v1")
            XCTAssertTrue(provider.loadLibrary(defaults: defaults).books.isEmpty)
            XCTAssertNil(NowPlayingProvider().loadNowPlaying(defaults: defaults).bookId)
            XCTAssertNil(ContinueReadingProvider().loadContinueReading(defaults: defaults).bookId)
            try seedBooks(defaults)
            XCTAssertEqual(provider.loadLibrary(defaults: defaults).books.count, 6)
        }
        XCTAssertTrue(WidgetSharedLibrary.loadBooks(defaults: nil).isEmpty)
        XCTAssertNil(NowPlayingProvider().loadNowPlaying(defaults: nil).bookId)
    }

    func testCommandsPersistBeforeNotificationAndLeaveUnrelatedFlagsAlone() throws {
        try withDefaults { defaults in
            defaults.set("keep", forKey: "unrelated")
            var notifications = 0
            WidgetPlaybackCommand.togglePlayPause.send(defaults: defaults) {
                XCTAssertTrue(defaults.bool(forKey: "widget.intent.togglePlayPause"))
                XCTAssertFalse(defaults.bool(forKey: "widget.intent.skipForward30"))
                notifications += 1
            }
            WidgetPlaybackCommand.skipForward30.send(defaults: defaults) {
                XCTAssertTrue(defaults.bool(forKey: "widget.intent.skipForward30"))
                notifications += 1
            }
            XCTAssertEqual(notifications, 2)
            XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
            XCTAssertEqual(WidgetPlaybackCommand.notificationName, "com.pietrocode.epubtomp3.widgetIntent")
        }
        var notified = false
        WidgetPlaybackCommand.togglePlayPause.send(defaults: nil) { notified = true }
        XCTAssertTrue(notified)
    }

    func testCoverThumbnailBoundsDecodedPixelsAndPreservesUnreadableInput() throws {
        XCTAssertNil(WidgetCoverThumbnail.make(nil))
        XCTAssertNil(WidgetCoverThumbnail.make(Data()))
        let malformed = Data("not an image".utf8)
        XCTAssertEqual(WidgetCoverThumbnail.make(malformed), malformed)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 800,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let thumbnail = try XCTUnwrap(WidgetCoverThumbnail.make(data as Data))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 600)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 400)
    }
}
