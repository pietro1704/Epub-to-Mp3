import Foundation
import XCTest
#if os(macOS)
import AppKit
import AVFoundation
#endif
@testable import EpubToMp3

/// PDFKit produces the fixture; the embedded Rust artifact must extract it.
final class PdfEmbeddedConversionTests: XCTestCase {
    func testPDFKitDocumentOpensThroughBundledRustWithUnicodeTextAndMetadata() throws {
        let source = try PdfFixture.createMultiPage(title: "PDF narration fixture", author: "Fixture author", pages: [
            (heading: "Primeira parte", body: "Olá, ação e coração no primeiro texto."),
            (heading: "Segunda parte", body: "A segunda página continua o livro.")
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let payload = try metadata(source)
        XCTAssertEqual(payload["title"] as? String, "PDF narration fixture")
        XCTAssertEqual(payload["author"] as? String, "Fixture author")
        let chapters = try XCTUnwrap(payload["chapters"] as? [[String: Any]])
        XCTAssertEqual(chapters.count, 2)
        let text = chapters.compactMap { $0["text"] as? String }.joined(separator: " ")
        XCTAssertTrue(text.contains("ação"), text)
        XCTAssertTrue(text.contains("coração"), text)
        XCTAssertTrue(text.contains("segunda"), text)
        XCTAssertEqual(chapters[1]["sourcePath"] as? String, "page-2")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testReplacingPDFAtSamePathDoesNotReusePreviousMetadata() throws {
        let source = try PdfFixture.createSinglePage(title: "Original", bodyText: "Original readable passage.")
        let successor = try PdfFixture.createSinglePage(title: "Replacement", bodyText: "New readable passage.")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: successor)
        }
        XCTAssertEqual(try metadata(source)["title"] as? String, "Original")
        try Data(contentsOf: successor).write(to: source, options: .atomic)
        XCTAssertEqual(try metadata(source)["title"] as? String, "Replacement")
    }

    func testUnreadablePDFReportsExtractionFailureInsteadOfEPUBArchiveError() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("Not a PDF".utf8).write(to: source)
        XCTAssertThrowsError(try metadata(source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("PDF"))
            XCTAssertFalse(error.localizedDescription.contains("EOCD"))
        }
    }

    #if os(macOS)
    @MainActor
    func testVisiblePDFConvertButtonProducesPlayableSystemVoiceAudio() async throws {
        guard ProcessInfo.processInfo.environment["EPUB_PDF_GUI_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in visible/audible PDF acceptance")
        }
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(activationPolicy) }
        let suite = "PdfConversionAcceptance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let source = try PdfFixture.createSinglePage(title: "PDF to MP3 acceptance",
            bodyText: "Olá. Este PDF agora pode virar áudio.")
        let original = try Data(contentsOf: source)
        let library = LibraryStore(defaults: defaults, importDirectory: root.appendingPathComponent("library"))
        var book = try library.importBook(from: source)
        book.coverPNG = Data("Legacy cached PDF cover".utf8)
        book.pdfCoverVersion = nil
        library.update(book)
        try await library.flushPersistence()
        let settings = AppSettings(defaults: defaults)
        settings.audioEngine = .system
        settings.secondaryAudioEngine = nil
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let output = RustConversionOutputStore(root: root.appendingPathComponent("outputs"), notificationCenter: NotificationCenter())
        let completed = expectation(description: "Visible PDF conversion completes")
        var converted: RustConversionCoordinator.Result?
        var conversionError: String?
        let controller = MacBookDetailViewController(book: book, library: library, settings: settings,
            player: player, playerPresentation: PlayerPresentation(defaults: defaults), onRead: { _ in }, onShowJobs: {},
            conversionExecutor: { url, job, first, last, options, progress, chapter in
                defer { completed.fulfill() }
                do {
                    let result = try await RustConversionCoordinator(outputStore: output).convert(
                        bookURL: url, jobID: job, chapterStart: first, chapterEnd: last,
                        options: options, onProgress: progress, onChapterCompleted: chapter)
                    converted = result
                    return result
                } catch { conversionError = error.localizedDescription; throw error }
            })
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PDF to MP3 — installed system voice acceptance"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1000, height: 700)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.collectionBehavior.insert(.moveToActiveSpace)
        controller.view.layoutSubtreeIfNeeded()
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        // XCTest launches a background process. Ask Launch Services to activate
        // this existing application before asserting foreground acceptance.
        let activation = NSWorkspace.OpenConfiguration()
        activation.activates = true
        activation.createsNewApplicationInstance = false
        let running = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: activation)
        XCTAssertEqual(running.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: .activateAllWindows)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "bookDetail.convert" })
        var accepted = false
        let confirmation = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let modal = NSApp.modalWindow else { return }
                if !accepted { accepted = true; NSApp.stopModal(withCode: .alertFirstButtonReturn) }
                else { NSApp.abortModal() }
                modal.orderOut(nil)
            }
        }
        RunLoop.main.add(confirmation, forMode: .modalPanel)
        defer {
            confirmation.invalidate(); player.stop()
            window.orderOut(nil); window.contentViewController = nil; window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        button.scrollToVisible(button.bounds)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.isVisible)
        XCTAssertGreaterThan(button.visibleRect.height, 0)
        button.performClick(nil)
        XCTAssertTrue(accepted)
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: .activateAllWindows)
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        await fulfillment(of: [completed], timeout: 180)
        XCTAssertNil(conversionError)
        let result = try XCTUnwrap(converted, conversionError ?? "Missing PDF result")
        let snapshot = try result.snapshot()
        XCTAssertEqual(snapshot.engine, "system")
        let chapter = try XCTUnwrap(snapshot.chapterProgress?.first)
        let audioURL = URL(fileURLWithPath: try XCTUnwrap(chapter.downloadUrl))
        let decoded = try AVAudioFile(forReading: audioURL)
        XCTAssertGreaterThan(decoded.length, 0)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let refreshedBook = try XCTUnwrap(library.books.first(where: { $0.id == book.id }))
        XCTAssertEqual(refreshedBook.pdfCoverVersion, PdfMetadataReader.coverVersion)
        let refreshedImage = try XCTUnwrap(refreshedBook.coverPNG.flatMap(NSImage.init(data:)))
        XCTAssertTrue(descendants(controller.view).compactMap { $0 as? NSImageView }.contains {
            $0.image?.tiffRepresentation == refreshedImage.tiffRepresentation
        }, "The existing detail window must display the refreshed persisted cover")
        let audio = try AVAudioPlayer(contentsOf: audioURL)
        XCTAssertTrue(audio.play())
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertGreaterThan(audio.currentTime, 0)
        audio.stop()
        print("PDF_NATIVE_ACCEPTANCE engine=\(snapshot.engine ?? "unknown") voice=\(snapshot.voice ?? "unknown") frames=\(decoded.length)")
        let attachment = XCTAttachment(data: try Data(contentsOf: audioURL), uniformTypeIdentifier: "public.mp3")
        attachment.name = "pdf-system-voice-output.mp3"; attachment.lifetime = .keepAlways; add(attachment)
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let screenshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                screenshot.name = "visible-pdf-conversion-window"; screenshot.lifetime = .keepAlways; add(screenshot)
            }
        }
        XCTAssertTrue(window.occlusionState.contains(.visible))
    }
    #endif

    private func metadata(_ source: URL) throws -> [String: Any] {
        let book = try ConverterFFIAdapter().openBook(at: source)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: book.metadataJSON) as? [String: Any])
    }
}
