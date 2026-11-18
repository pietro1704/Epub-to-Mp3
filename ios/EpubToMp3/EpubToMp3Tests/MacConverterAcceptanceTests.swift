#if os(macOS)
import AppKit
import AVFoundation
import CoreGraphics
import XCTest
@testable import EpubToMp3

@MainActor
final class MacConverterAcceptanceTests: XCTestCase {
    func testVisibleConverterProducesPlayableAudioThroughTheEmbeddedRuntime() async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_CONVERTER_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit visible Converter acceptance with an installed system voice")
        }
        let suite = "MacConverterAcceptance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let source = try PdfFixture.createSinglePage(title: "Converter acceptance",
            bodyText: "Olá. A conversão manual preserva o livro e produz áudio local.")
        let original = try Data(contentsOf: source)
        let library = LibraryStore(defaults: defaults, importDirectory: root.appendingPathComponent("library"))
        let book = try library.importBook(from: source)
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(.selected(.system))
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
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 850),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Converter — installed system voice acceptance"
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 850))
        window.collectionBehavior.insert(.moveToActiveSpace)
        defer {
            session.cancel()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NSApp.setActivationPolicy(previousPolicy)
            defaults.removePersistentDomain(forName: suite)
            // A timed-out writer retains its evidence and files until it stops.
            if !session.isRunning { try? FileManager.default.removeItem(at: root) }
            try? FileManager.default.removeItem(at: source)
        }
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        let activation = NSWorkspace.OpenConfiguration()
        activation.activates = true
        activation.createsNewApplicationInstance = false
        let running = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: activation)
        XCTAssertEqual(running.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: .activateAllWindows)
        try await waitUntil {
            window.isVisible && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        }
        await controller.selectLibraryBook(book.id, startImmediately: false)
        XCTAssertEqual(controller.selectedBookID, book.id)
        XCTAssertTrue(controller.form.pronunciation.isEnabled)
        controller.form.language.stringValue = "pt-BR"
        controller.form.submit.scrollToVisible(controller.form.submit.bounds)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.form.submit.visibleRect.height, 0)
        attach(window, name: "converter-before-submit")

        // Exercise the ordinary button action and real Rust/Apple system adapter.
        controller.form.submit.performClick(nil)
        try await waitUntil(timeout: 180) { session.phase == .completed || session.phase == .failed }
        XCTAssertEqual(session.phase, .completed, session.errorMessage ?? "Conversion did not complete")
        let result = try XCTUnwrap(session.result, session.errorMessage ?? "Missing conversion result")
        try await waitUntil { library.books.first(where: { $0.id == book.id })?.lastJobId == result.jobID }
        let snapshot = try result.snapshot()
        XCTAssertEqual(snapshot.engine, "system")
        let chapter = try XCTUnwrap(snapshot.playableChapters.first)
        let audioURL = URL(fileURLWithPath: try XCTUnwrap(chapter.downloadUrl))
        let decoded = try AVAudioFile(forReading: audioURL)
        XCTAssertGreaterThan(decoded.length, 0)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(controller.form.revealResult.isHidden)
        XCTAssertTrue(controller.form.failure.isHidden)
        XCTAssertTrue(controller.form.pronunciation.isEnabled)
        controller.form.result.scrollToVisible(controller.form.result.bounds)
        controller.view.layoutSubtreeIfNeeded()
        attach(window, name: "converter-completed")
        let audio = XCTAttachment(data: try Data(contentsOf: audioURL), uniformTypeIdentifier: "public.mp3")
        audio.name = "converter-system-voice.mp3"
        audio.lifetime = .keepAlways
        add(audio)
        print("CONVERTER_ACCEPTANCE engine=\(snapshot.engine ?? "unknown") voice=\(snapshot.voice ?? "unknown") frames=\(decoded.length)")
        XCTAssertTrue(window.occlusionState.contains(.visible))
    }

    private func waitUntil(timeout: TimeInterval = 10, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Converter acceptance condition timed out")
                throw NSError(domain: "MacConverterAcceptance", code: 1)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func attach(_ window: NSWindow, name: String) {
        // Capture the actual visible window, including its semantic background.
        // A transparent view-only bitmap hides dark labels in evidence viewers.
        guard let capture = CGWindowListCreateImage(.null, .optionIncludingWindow,
            CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
            XCTFail("Cannot capture the visible Converter window")
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: capture)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Cannot encode Converter capture")
            return
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
