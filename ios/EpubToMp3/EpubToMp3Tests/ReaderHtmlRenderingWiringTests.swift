import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderHtmlRenderingWiringTests: XCTestCase {
    func testNativeChapterSurfaceUsesAuthoredHTMLInsteadOfNarrationFallback() throws {
        let harness = try NativeReaderTestHarness(chapters: [
            NativeReaderTestHarness.chapter("Narration fallback", html: "<p>Authored <strong>HTML passage</strong>.</p>")
        ])
        harness.installTeardown(in: self)
        harness.showChapter(0)
        XCTAssertTrue(harness.displayed.string.contains("Authored HTML passage"))
        XCTAssertFalse(harness.displayed.string.contains("Narration fallback"))
        XCTAssertFalse(harness.displayed.string.contains("<strong>"))
    }

    func testNativeChapterSurfaceRetainsPlainTextWhenHTMLIsAbsent() throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Plain readable passage.")])
        harness.installTeardown(in: self)
        harness.showChapter(0)
        XCTAssertEqual(harness.displayed.string.trimmingCharacters(in: .whitespacesAndNewlines), "Plain readable passage.")
    }

    func testFulltextCacheUsesDurableApplicationSupportInsteadOfLegacyCaches() throws {
        let url = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: "cache-directory-contract"))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "ReaderFulltext-v2")
        XCTAssertEqual(url.pathExtension, "plist")
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        XCTAssertTrue(url.path.hasPrefix(support.path + "/"))
    }
}
