#if os(macOS)
import AppKit
import CoreGraphics
import XCTest
@testable import EpubToMp3

/// PDF-COVER-BLOCKS-CONVERSION: pages without selectable text are skipped and
/// announced in the visible Converter; only a PDF with no text at all asks for
/// OCR. Runs through the real embedded Rust runtime.
@MainActor
final class MacConverterOCRMessageTests: XCTestCase {
    func testImageOnlyCoverConvertsAndAnnouncesTheSkippedPage() async throws {
        try await convert(pages: [nil,
            "Chapter one. The morning was quiet and the children walked to the school with their friends.",
            "Chapter two. They returned home in the evening and told their parents everything about the day."]) { controller, session, window in
            XCTAssertEqual(session.phase, .completed, session.errorMessage ?? "")
            let notice = L10n.string("convert.pdfPagesSkipped.one")
            XCTAssertNotEqual(notice, "convert.pdfPagesSkipped.one")
            await self.poll { controller.form.status.stringValue.contains(notice) }
            XCTAssertTrue(controller.form.status.stringValue.contains(notice), controller.form.status.stringValue)
            XCTAssertFalse(controller.form.status.isHiddenOrHasHiddenAncestor)
            self.show(controller.form.status, in: controller)
            self.attach(window, name: "mac-converter-pdf-pages-skipped")
        }
    }

    func testScannedPDFShowsTheOCRMessageInTheConverter() async throws {
        try await convert(pages: [nil, nil, nil]) { controller, session, window in
            XCTAssertEqual(session.phase, .failed)
            let message = L10n.string("error.pdfOcrRequired")
            XCTAssertNotEqual(message, "error.pdfOcrRequired")
            await self.poll { controller.form.failure.stringValue == message }
            XCTAssertEqual(controller.form.failure.stringValue, message)
            XCTAssertFalse(controller.form.failure.isHiddenOrHasHiddenAncestor)
            self.show(controller.form.failure, in: controller)
            self.attach(window, name: "mac-converter-pdf-ocr-required")
        }
    }

    private func poll(_ condition: () -> Bool) async {
        for _ in 0..<40 where !condition() { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func show(_ label: NSView, in controller: NSViewController) {
        label.scrollToVisible(label.bounds)
        controller.view.layoutSubtreeIfNeeded()
    }

    private func convert(
        pages: [String?],
        inspect: (MacConvertScreenController, ManualConversionSession, NSWindow) async throws -> Void
    ) async throws {
        let suite = "MacConverterOCR.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Synthetic pages.pdf")
        try Self.writePDF(pages: pages, to: source)
        let library = LibraryStore(defaults: defaults, importDirectory: root.appendingPathComponent("library"))
        let book = try library.importBook(from: source)
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(.systemDefault)
        settings.selectSecondaryNarration(nil)
        let output = RustConversionOutputStore(root: root.appendingPathComponent("outputs"),
                                              notificationCenter: NotificationCenter())
        let session = ManualConversionSession(executor: { url, job, first, last, options, progress, chapter in
            try await RustConversionCoordinator(outputStore: output).convert(
                bookURL: url, jobID: job, chapterStart: first, chapterEnd: last,
                options: options, onProgress: progress, onChapterCompleted: chapter)
        })
        let controller = MacConvertScreenController(settings: settings, library: library,
                                                   viewModel: ConvertViewModel(session: session))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 850),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 850))
        defer {
            session.cancel()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
            if !session.isRunning { try? FileManager.default.removeItem(at: root) }
        }
        window.orderFrontRegardless()

        await controller.selectLibraryBook(book.id, startImmediately: false)
        XCTAssertEqual(controller.selectedBookID, book.id)
        controller.form.submit.performClick(nil)
        let deadline = Date().addingTimeInterval(120)
        while session.phase != .failed && session.phase != .completed {
            guard Date() < deadline else { return XCTFail("The conversion did not finish") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await inspect(controller, session, window)
    }

    /// A nil page draws only an image (like a scanned cover); the others carry real text.
    private static func writePDF(pages: [String?], to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "MacConverterOCR", code: 1)
        }
        let pixels = CGContext(data: nil, width: 64, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        pixels?.setFillColor(NSColor.systemTeal.cgColor)
        pixels?.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        guard let cover = pixels?.makeImage() else { throw NSError(domain: "MacConverterOCR", code: 2) }
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                (text as NSString).draw(in: CGRect(x: 72, y: 500, width: 468, height: 220),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
                NSGraphicsContext.restoreGraphicsState()
            } else {
                context.draw(cover, in: box.insetBy(dx: 60, dy: 60))
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func attach(_ window: NSWindow, name: String) {
        let png: Data?
        if let capture = CGWindowListCreateImage(.null, .optionIncludingWindow,
            CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            png = NSBitmapImageRep(cgImage: capture).representation(using: .png, properties: [:])
        } else if let content = window.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            png = bitmap.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png else { return XCTFail("Cannot capture the Converter window") }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
