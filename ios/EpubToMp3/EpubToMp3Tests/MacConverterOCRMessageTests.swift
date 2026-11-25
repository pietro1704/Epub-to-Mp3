#if os(macOS)
import AppKit
import CoreGraphics
import XCTest
@testable import EpubToMp3

/// PDF-COVER-BLOCKS-CONVERSION (a): visual evidence that converting a PDF whose
/// cover is an image-only page shows the localized OCR message in the visible
/// Converter, through the real embedded Rust runtime.
@MainActor
final class MacConverterOCRMessageTests: XCTestCase {
    func testImageOnlyCoverShowsTheOCRMessageInTheConverter() async throws {
        let suite = "MacConverterOCR.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Image cover.pdf")
        try Self.writeImageCoverPDF(to: source)
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
        XCTAssertEqual(session.phase, .failed)
        let message = L10n.string("error.pdfOcrRequired")
        XCTAssertNotEqual(message, "error.pdfOcrRequired")
        for _ in 0..<40 where controller.form.failure.stringValue != message {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(controller.form.failure.stringValue, message)
        XCTAssertFalse(controller.form.failure.isHiddenOrHasHiddenAncestor)
        controller.form.failure.scrollToVisible(controller.form.failure.bounds)
        controller.view.layoutSubtreeIfNeeded()
        attach(window, name: "mac-converter-pdf-ocr-required")
    }

    /// Page 1 draws only an image (a scanned cover); pages 2-3 carry real text.
    private static func writeImageCoverPDF(to url: URL) throws {
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
        context.beginPDFPage(nil)
        context.draw(cover, in: box.insetBy(dx: 60, dy: 60))
        context.endPDFPage()
        for text in ["Chapter one. This page has selectable text.", "Chapter two. The end."] {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 72, y: 700),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            NSGraphicsContext.restoreGraphicsState()
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
