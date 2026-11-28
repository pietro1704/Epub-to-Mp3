import XCTest
@testable import EpubToMp3
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "Listen from this page" starts at the first text on screen. The core applies the published ratio
/// to the chapter's narration text, which is not laid out like the rendered page.
@MainActor
final class ReaderPlayFromPageTests: XCTestCase {
    private let sentences = (1...300).map { "Sentence \($0) sails past the headland." }

    /// The narration offset the core derives from the published ratio.
    private func narrationAtPublishedPage(_ harness: NativeReaderTestHarness, source: String) throws -> String {
        let ratio = try XCTUnwrap(harness.player.location.pageRatio)
        let offset = Int((Double(source.unicodeScalars.count) * ratio).rounded(.down))
        return String(String.UnicodeScalarView(source.unicodeScalars.dropFirst(offset)))
    }

    private func firstSentence(in text: String) throws -> Int {
        let match = try XCTUnwrap(text.range(of: #"Sentence \d+"#, options: .regularExpression), String(text.prefix(80)))
        return try XCTUnwrap(Int(text[match].dropFirst("Sentence ".count)))
    }

    #if os(macOS)
    func testListeningFromAPageStartsAtItsTextWhenTheLayoutDiffersFromTheNarration() async throws {
        let source = sentences.joined(separator: "\n")
        // Publisher spacing exists on the page only, and only in the first half of the chapter.
        let html = sentences.enumerated().map { index, sentence in
            "<p>\(sentence)</p>" + (index < 150 ? String(repeating: "<p>&nbsp;</p>", count: 20) : "")
        }.joined()
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter(source, html: html)])
        harness.installTeardown(in: self)
        harness.controller.view.layoutSubtreeIfNeeded()
        harness.showChapter(0)
        try await Task.sleep(nanoseconds: 700_000_000)
        let textView = harness.composition.textView
        XCTAssertGreaterThan(textView.string.utf16.count, source.utf16.count, "the page must be laid out from the HTML")
        let target = (textView.string as NSString).range(of: "Sentence 200 ")
        let layout = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layout.ensureLayout(for: container)
        let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: target.location), effectiveRange: nil)
        let clip = harness.composition.contentScrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: line.minY + textView.textContainerOrigin.y))
        let visible = try XCTUnwrap(MacReaderTextLayout.characterRange(in: clip.documentVisibleRect, of: textView))
        let shown = try firstSentence(in: (textView.string as NSString).substring(from: visible.location))

        harness.text.persistReadingProgress()

        let narrated = try firstSentence(in: narrationAtPublishedPage(harness, source: source))
        XCTAssertLessThanOrEqual(abs(narrated - shown), 1, "page shows \(shown), narration starts at \(narrated)")
    }
    #else
    func testASmallStepInAVeryLongChapterStillMovesTheListeningPosition() throws {
        let source = (1...3000).map { "Sentence \($0) sails past the headland." }.joined(separator: "\n")
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter(source)])
        harness.installTeardown(in: self)
        harness.composition.textView.text = source
        let playback = ReaderPlaybackPosition(document: harness.document, composition: harness.composition,
                                              location: harness.player.location)
        let facts = ReaderReadingPosition.Facts(chromeHidden: false, isPaginated: true, isLoading: false, layoutResult: nil)
        let rendered = source as NSString

        for sentence in [1500, 1502] {
            playback.publish(.init(offsetFraction: 0, characterOffset: rendered.range(of: "Sentence \(sentence) ").location),
                             facts: facts, isViewportTransitioning: false)
        }

        XCTAssertEqual(try firstSentence(in: narrationAtPublishedPage(harness, source: source)), 1502)
    }
    #endif
}
