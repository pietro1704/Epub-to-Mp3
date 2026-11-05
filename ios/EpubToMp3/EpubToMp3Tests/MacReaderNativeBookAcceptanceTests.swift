#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// Opt-in real-book typography on the installed AppKit text surface. The
/// fixture remains private; neither the book nor a user library is rewritten.
@MainActor
final class MacReaderNativeBookAcceptanceTests: XCTestCase {
    func testRealLOTRTypographyAtSmallAndDefaultSizesPreservesFinalGlyphAndViewport() async throws {
        guard let path = ProcessInfo.processInfo.environment["EPUBTOMP3_LOTR_SOURCE"],
              FileManager.default.fileExists(atPath: path),
              let prepared = ProcessInfo.processInfo.environment["EPUBTOMP3_LOTR_PREPARED"],
              FileManager.default.fileExists(atPath: prepared) else {
            throw XCTSkip("Requires an explicitly supplied local LOTR EPUB")
        }
        let source = URL(fileURLWithPath: path)
        let standard = UserDefaults.standard
        let savedProgress = standard.object(forKey: "readerProgress.v1")
        defer { standard.set(savedProgress, forKey: "readerProgress.v1") }
        let payload = try await Task.detached {
            try PropertyListDecoder().decode(EbookFulltext.self, from: Data(contentsOf: URL(fileURLWithPath: prepared)))
        }.value
        let index = try XCTUnwrap(payload.chapters.firstIndex {
            $0.name?.localizedCaseInsensitiveContains("Many Meetings") == true
        })
        let chapter = payload.chapters[index]
        XCTAssertGreaterThan(chapter.text.count, 10_000)
        let sourcePath = try XCTUnwrap(chapter.sourcePath)
        let originalHTML = try XCTUnwrap(ZipReader.extract(member: sourcePath, from: source))
        XCTAssertEqual(String(data: originalHTML, encoding: .utf8), chapter.html,
            "Retained typography must exactly match this original EPUB chapter")
        NSLog("MAC_LOTR prepared chapter=%d characters=%d", index, chapter.text.count)
        let harness = try NativeReaderTestHarness(chapters: payload.chapters)
        harness.installTeardown(in: self)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = harness.controller
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        for (fontStep, pointSize) in [(0, 14), (3, 24)] {
            harness.settings.readerOverrideFontSize = true
            harness.settings.readerFontSize = fontStep
            XCTAssertEqual(harness.settings.readerPointSize, CGFloat(pointSize))
            harness.settings.readerOverrideFontFamily = false
            NSLog("MAC_LOTR layout beginning pointSize=%d", pointSize)
            harness.showChapter(index)
            window.layoutIfNeeded()
            NSLog("MAC_LOTR chapter mounted pointSize=%d", pointSize)
            let text = harness.composition.textView
            let scroll = harness.composition.contentScrollView
            MacReaderTextLayout.fit(text, in: scroll)
            let manager = try XCTUnwrap(text.layoutManager)
            let container = try XCTUnwrap(text.textContainer)
            manager.ensureLayout(for: container)
            XCTAssertGreaterThan(text.string.utf16.count, 10_000)
            XCTAssertGreaterThan(text.frame.height, scroll.contentView.bounds.height * 2)
            let attributedBaseline = NSAttributedString(attributedString: text.attributedString())
            let height = text.frame.height
            let used = manager.usedRect(for: container)
            let end = max(0, height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
            scroll.reflectScrolledClipView(scroll.contentView)
            let offset = scroll.contentView.bounds.origin
            let visible = scroll.contentView.documentVisibleRect
            XCTAssertLessThanOrEqual(used.maxY, visible.maxY + 0.5,
                "The final real-book line must fit the committed viewport")
            XCTAssertLessThanOrEqual(visible.maxY - used.maxY, text.textContainerInset.height * 2 + 0.5,
                "No unexplained blank tail after the actual chapter")
            let lastGlyph = try XCTUnwrap((0..<manager.numberOfGlyphs).reversed().first {
                !manager.boundingRect(forGlyphRange: NSRange(location: $0, length: 1), in: container).isEmpty
            })
            let glyphBounds = manager.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: container)
                .offsetBy(dx: text.textContainerInset.width, dy: text.textContainerInset.height)
            XCTAssertLessThanOrEqual(glyphBounds.maxY, visible.maxY + 0.5)
            XCTAssertGreaterThanOrEqual(glyphBounds.minY, visible.minY - 0.5)
            MacReaderTextLayout.fit(text, in: scroll)
            text.layoutSubtreeIfNeeded()
            XCTAssertEqual(text.frame.height, height, accuracy: 0.5)
            XCTAssertEqual(scroll.contentView.bounds.origin, offset, "Passive relayout must retain the exact raw offset")
            XCTAssertEqual(text.attributedString(), attributedBaseline, "Layout must preserve native typography and content")
            let evidence = XCTAttachment(string: "fontStep=\(fontStep) pointSize=\(pointSize) chapter=\(index) glyphs=\(manager.numberOfGlyphs) used=\(used) viewport=\(visible) finalGlyph=\(glyphBounds) offset=\(offset)")
            evidence.name = "real-lotr-native-typography-\(pointSize)"
            evidence.lifetime = .keepAlways
            add(evidence)
            if let snapshot = harness.controller.view.bitmapImageRepForCachingDisplay(in: harness.controller.view.bounds) {
                harness.controller.view.cacheDisplay(in: harness.controller.view.bounds, to: snapshot)
                let image = NSImage(size: harness.controller.view.bounds.size)
                image.addRepresentation(snapshot)
                let screenshot = XCTAttachment(image: image)
                screenshot.name = "real-lotr-native-final-viewport-\(pointSize)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            // Native Mac reader page actions move the same real text surface.
            harness.text.scrollPage(forward: false)
            XCTAssertLessThan(scroll.contentView.bounds.origin.y, end)
            harness.text.scrollPage(forward: true)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, end, accuracy: 0.5)
            XCTAssertEqual(harness.document.selectedChapter, index)
        }
    }
}
#endif
