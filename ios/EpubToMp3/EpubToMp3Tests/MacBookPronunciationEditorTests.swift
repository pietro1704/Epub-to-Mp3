#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacBookPronunciationEditorTests: XCTestCase {
    func testNativeSaveAndCancelOnlyAffectTheChosenBook() throws {
        let suite = "MacPronunciationEditor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BookPronunciationStore(defaults: defaults)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentViewController: controller)
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        defer { window.close() }

        for save in [true, false] {
            let watchdog = DispatchWorkItem { NSApp.abortModal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: watchdog)
            DispatchQueue.main.async {
                guard let content = NSApp.modalWindow?.contentView else { return XCTFail("Pronunciation editor must be visible") }
                let controls = self.descendants(content)
                let editor = controls.compactMap { $0 as? NSTextView }.first
                XCTAssertNotNil(editor)
                editor?.string = save ? "Tolkien = Tólkien" : "discarded = change"
                XCTAssertTrue(NSApp.modalWindow?.isVisible == true)
                content.layoutSubtreeIfNeeded()
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                        attachment.name = save ? "pronunciation-explicit-save" : "pronunciation-cancel"
                        attachment.lifetime = .keepAlways
                        self.add(attachment)
                    }
                }
                let title = save ? L10n.string("pronunciation.save") : L10n.string("common.cancel")
                let action = controls.compactMap { $0 as? NSButton }.first { $0.title == title }
                XCTAssertNotNil(action)
                action?.performClick(nil)
            }
            BookPronunciationEditor.present(bookID: "chosen-book", on: controller, store: store)
            watchdog.cancel()
            XCTAssertEqual(store.load(bookID: "chosen-book").editableText, "Tolkien = Tólkien")
            XCTAssertTrue(store.load(bookID: "other-book").rules.isEmpty)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
