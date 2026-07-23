import XCTest
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import EpubToMp3

/// Regression tests for the scroll-mode flicker fix.
///
/// Root cause: in the continuous full-book scroll (`ReaderView`'s
/// `LazyVStack` of `BookChapterCell`), a cell that scrolls out of the
/// viewport is DESTROYED — its `@State attributed` is lost. When the user
/// scrolled it back, the cell blanked to its `Color.clear` placeholder and
/// re-ran `EpubHtmlRenderer.render` (50–200 ms, main-thread WebKit importer):
/// the chapter text visibly vanished and repainted a frame later. That is the
/// "flicker no modo rolagem" the user saw on the physical device.
///
/// Fix: `BookChapterRenderCache` (an `NSCache`) keyed on the same identity
/// string (`renderKey`) that gates a re-render. A recycled cell reads the
/// cache synchronously in `body` and paints instantly — no blank frame, no
/// re-parse. These tests pin that contract.
@MainActor
final class BookChapterRenderCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        BookChapterRenderCache.removeAll()
    }

    /// A recycled cell must retrieve the already-parsed render instead of
    /// re-parsing (which is what caused the blank-then-repaint flicker).
    func testReturnsStoredValue() {
        let key = "5|serif|18|dark"
        XCTAssertNil(BookChapterRenderCache.value(for: key),
                     "cache must start empty for this key")
        BookChapterRenderCache.store(NSAttributedString(string: "chapter body"), for: key)
        XCTAssertEqual(BookChapterRenderCache.value(for: key)?.string, "chapter body")
    }

    /// The cache is keyed by render identity, so any change to a setting the
    /// renderer reads (font size, theme…) is a cache MISS and forces a fresh
    /// parse — the cache must never serve a stale render across a genuine
    /// identity change.
    func testMissesOnDifferentKey() {
        BookChapterRenderCache.store(NSAttributedString(string: "old"), for: "5|serif|18|dark")
        XCTAssertNil(BookChapterRenderCache.value(for: "5|serif|24|dark"),
                     "a different renderKey (font size changed) must not hit the cache")
    }

    /// Overwriting the same key replaces the render (e.g. a chapter re-parsed
    /// after a settings change lands under a new key; the old key can be
    /// re-stored fresh without leaking the previous value).
    func testStoreOverwrites() {
        let key = "9|sans|18|light"
        BookChapterRenderCache.store(NSAttributedString(string: "first"), for: key)
        BookChapterRenderCache.store(NSAttributedString(string: "second"), for: key)
        XCTAssertEqual(BookChapterRenderCache.value(for: key)?.string, "second")
    }

    /// `ReaderView`'s neighbour-chapter prefetch (added for the scroll-mode
    /// single-chapter redesign, 2026-07-08) computes the cache key via the
    /// static `BookChapterCell.renderKey` helper WITHOUT a live cell
    /// instance. This must produce the exact same key a `BookChapterCell`
    /// would compute for the same chapter/settings, or a prefetched entry
    /// would never be a cache hit when the cell actually renders.
    @MainActor
    func testStaticRenderKeyMatchesInstanceKey() {
        let settings = AppSettings()
        let chapter = EbookFulltext.Chapter(
            index: 3, name: "Cap III", text: "body text", html: nil, css: nil,
            charCount: 9, segments: nil
        )
        let staticKey = BookChapterCell.renderKey(
            chapter: chapter, settings: settings, fontSize: 18, lineSpacing: 1.5,
            namespace: "book-a"
        )
        let cell = BookChapterCell(
            chapter: chapter, renderNamespace: "book-a", settings: settings,
            fontDirectoryURL: nil, columnWidth: 300, margin: 16,
            fontSize: 18, lineSpacing: 1.5
        )
        XCTAssertEqual(cell.renderKey, staticKey)
        BookChapterRenderCache.store(NSAttributedString(string: "prefetched"), for: staticKey)
        XCTAssertEqual(BookChapterRenderCache.value(for: staticKey)?.string, "prefetched")

        let otherBook = BookChapterCell(
            chapter: chapter, renderNamespace: "book-b", settings: settings,
            fontDirectoryURL: nil, columnWidth: 300, margin: 16,
            fontSize: 18, lineSpacing: 1.5
        )
        XCTAssertNotEqual(cell.renderKey, otherBook.renderKey)
    }

    /// The static `renderAttributed` helper must produce usable plain-text
    /// output for a chapter with no HTML payload (the fallback path scroll
    /// mode's prefetch relies on for non-HTML fixtures).
    @MainActor
    func testStaticRenderAttributedPlainFallback() {
        let settings = AppSettings()
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "Cap I", text: "Hello world", html: nil, css: nil,
            charCount: 11, segments: nil
        )
        let rendered = BookChapterCell.renderAttributed(
            chapter: chapter, settings: settings, fontDirectoryURL: nil,
            fontSize: 18, lineSpacing: 1.5
        )
        XCTAssertEqual(rendered.string, "Hello world")
    }
}
