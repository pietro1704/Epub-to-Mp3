import Foundation
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

final class PreparedChapterRendererTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-renderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func settings() throws -> AppSettings {
        let suite = "prepared-renderer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.readerTheme = .light
        return settings
    }

    private func chapter(index: Int = 1, html: String = "<h2>Heading</h2><p><b>Bold</b> <i>italic</i> <a href='#note'>note</a>.</p>",
                         css: String? = "p { color: #123456; text-indent: 12px; }",
                         text: String = "Independent parser text") -> EbookFulltext.Chapter {
        .init(index: index, name: "Fixture", sourcePath: "chapter.xhtml", text: text,
              html: html, css: css, charCount: text.count, segments: nil)
    }

    @MainActor
    func testMemoryHitAndReopenedRendererPreserveNativeAttributes() async throws {
        let store = PreparedChapterArchiveStore(directory: root)
        let renderer = PreparedChapterRenderer(store: store)
        let settings = try settings()
        let chapter = chapter()
        let first = try XCTUnwrap(renderer.render(bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings))
        let memory = try XCTUnwrap(renderer.cached(bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings))
        XCTAssertFalse(first === memory)
        XCTAssertEqual(first, memory)
        XCTAssertFalse(first is NSMutableAttributedString)
        XCTAssertEqual(first, try XCTUnwrap(renderer.render(
            bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings)))
        XCTAssertNotNil(first.attribute(.font, at: 0, effectiveRange: nil))
        XCTAssertNotNil(first.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        var hasLink = false
        first.enumerateAttribute(.link, in: NSRange(location: 0, length: first.length)) { value, _, _ in
            if value != nil { hasLink = true }
        }
        XCTAssertTrue(hasLink)
        await renderer.flush()
        let reopened = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: root))
        XCTAssertNil(reopened.cached(bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings))
        let restored = await reopened.restore(bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings)
        XCTAssertEqual(first, try XCTUnwrap(restored))
        XCTAssertNotNil(reopened.cached(bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings))
    }

    @MainActor
    func testEveryRendererSettingInvalidatesPreparedArchive() async throws {
        let store = PreparedChapterArchiveStore(directory: root)
        let renderer = PreparedChapterRenderer(store: store)
        let baseline = try settings()
        let chapter = chapter()
        XCTAssertNotNil(renderer.render(bookID: "book", chapterIndex: 0, chapter: chapter, settings: baseline))
        await renderer.flush()
        let mutations: [(AppSettings) -> Void] = [
            { $0.readerBoldOverride.toggle() },
            { $0.readerCustomColors = (background: (0.1, 0.2, 0.3), foreground: (0.4, 0.5, 0.6)) },
            { $0.readerFontFamily = .mono }, { $0.readerLetterSpacing = 1 },
            { $0.readerLineSpacing += 1 }, { $0.readerOverrideColours.toggle() },
            { $0.readerOverrideFontFamily.toggle() }, { $0.readerOverrideFontSize.toggle() },
            { $0.readerFontSize = 0 }, { $0.readerSuppressItalic.toggle() },
            { $0.readerTextAlignment = .left }, { $0.readerTheme = .dark }
        ]
        for (index, mutate) in mutations.enumerated() {
            let changed = try settings()
            mutate(changed)
            XCTAssertNil(renderer.cached(bookID: "book", chapterIndex: 0, chapter: chapter, settings: changed),
                         "Memory setting mutation \(index)")
            let restored = await renderer.restore(bookID: "book", chapterIndex: 0, chapter: chapter, settings: changed)
            XCTAssertNil(restored, "Archive setting mutation \(index)")
        }
    }

    @MainActor
    func testSourceChapterBookAndFontDirectoryInvalidateArchive() async throws {
        let store = PreparedChapterArchiveStore(directory: root)
        let renderer = PreparedChapterRenderer(store: store)
        let settings = try settings()
        let original = chapter()
        XCTAssertNotNil(renderer.render(bookID: "book", chapterIndex: 0, chapter: original, settings: settings))
        await renderer.flush()
        for changed in [chapter(html: "<p>Changed HTML</p>"), chapter(css: "p {color:red}"),
                        chapter(text: "Changed parser payload"), chapter(index: 2)] {
            let value = await renderer.restore(bookID: "book", chapterIndex: 0, chapter: changed, settings: settings)
            XCTAssertNil(value)
        }
        let otherChapter = await renderer.restore(bookID: "book", chapterIndex: 1, chapter: original, settings: settings)
        let otherBook = await renderer.restore(bookID: "other", chapterIndex: 0, chapter: original, settings: settings)
        let fontChanged = await renderer.restore(bookID: "book", chapterIndex: 0, chapter: original,
                                                settings: settings, fontDirectoryURL: root)
        XCTAssertNil(otherChapter)
        XCTAssertNil(otherBook)
        XCTAssertNil(fontChanged)
    }

    @MainActor
    func testSettingsChangedDuringDiskAwaitDoNotRestoreStaleArchive() async throws {
        let store = PreparedChapterArchiveStore(directory: root)
        let renderer = PreparedChapterRenderer(store: store)
        let settings = try settings()
        let chapter = chapter()
        XCTAssertNotNil(renderer.render(bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings))
        await renderer.flush()
        let reopened = PreparedChapterRenderer(store: store)
        let mutation = Task { @MainActor in settings.readerBoldOverride = true }
        let value = await reopened.restore(bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings)
        await mutation.value
        XCTAssertNil(value)
    }

    @MainActor
    func testCorruptAndUnsupportedArchivesMissWithoutRenderingAndHTMLFallbackKeepsFidelity() async throws {
        let store = PreparedChapterArchiveStore(directory: root)
        let settings = try settings()
        let chapter = chapter()
        let initial = PreparedChapterRenderer(store: store)
        let expected = try XCTUnwrap(initial.render(bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings))
        await initial.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let envelope = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        let signature = try XCTUnwrap(envelope["signature"] as? String)
        let unsupported = try NSKeyedArchiver.archivedData(withRootObject: NSString(string: "Wrong root class"), requiringSecureCoding: true)
        for bad in [Data("Malformed archive".utf8), unsupported] {
            try await store.write(bad, bookID: "book", chapterIndex: 0, signature: signature)
            let reopened = PreparedChapterRenderer(store: store)
            let miss = await reopened.restore(bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings)
            XCTAssertNil(miss)
            XCTAssertNil(reopened.cached(bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings))
            let fallback = try XCTUnwrap(reopened.render(bookID: "book", chapterIndex: 0, chapter: chapter, settings: settings))
            XCTAssertTrue(expected.isEqual(to: fallback))
            await reopened.flush()
        }
        let empty = self.chapter(html: "")
        let miss = await initial.restore(bookID: "empty", chapterIndex: 0, chapter: empty, settings: settings)
        XCTAssertNil(miss)
        XCTAssertNil(initial.render(bookID: "empty", chapterIndex: 0, chapter: empty, settings: settings))
    }
}
