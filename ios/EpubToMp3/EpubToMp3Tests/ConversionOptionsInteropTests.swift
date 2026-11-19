import Foundation
import XCTest
import AVFoundation
import ImageIO
#if os(macOS) && !APP_FOUNDATION_HOST_TESTS
import AppKit
#endif
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ConversionOptionsInteropTests: XCTestCase {
    #if os(macOS) && !APP_FOUNDATION_HOST_TESTS


    @MainActor
    func exerciseMacConvertButton(engine: String) async throws {
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(activationPolicy) }
        let source = try EpubFixture.createWithChapter(
            body: "Este pequeno capítulo valida a conversão pela janela do aplicativo.",
            includeCover: false, language: "pt-BR")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-edge-ui-\(UUID().uuidString)")
        let suite = "MacEdgeUI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let library = LibraryStore(defaults: defaults, importDirectory: root)
        let book = try library.importBook(from: source)
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(.engineDefault(engine))
        settings.selectSecondaryNarration(nil)
        let completed = expectation(description: "The real conversion submitted by the macOS button finishes")
        var converted: RustConversionCoordinator.Result?
        var conversionError: String?
        let outputStore = RustConversionOutputStore(root: root.appendingPathComponent("outputs"), notificationCenter: NotificationCenter())
        let model = ConvertViewModel(session: ManualConversionSession(executor: { url, job, first, last, options, progress, chapter in
            defer { completed.fulfill() }
            XCTAssertEqual(options?.ttsPreferences?.primary.engine, engine)
            XCTAssertNil(options?.ttsPreferences?.secondary)
            do {
                let result = try await RustConversionCoordinator(outputStore: outputStore).convert(
                    bookURL: url, jobID: job, chapterStart: first, chapterEnd: last,
                    options: options, onProgress: progress, onChapterCompleted: chapter)
                converted = result
                return result
            } catch {
                conversionError = error.localizedDescription
                throw error
            }
        }))
        let controller = MacConvertScreenController(settings: settings, library: library, viewModel: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(TtsSelection.displayName(forEngine: engine) ?? engine) conversion validation — one chapter, no playback"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1000, height: 700)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 700))
        controller.view.layoutSubtreeIfNeeded()
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: .activateAllWindows)
        XCTAssertTrue(window.isOnActiveSpace)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        defer {
            window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        // The library context selects the exact book; the visible Convert button submits it.
        await controller.selectLibraryBook(book.id, startImmediately: false)
        XCTAssertEqual(controller.selectedBookID, book.id)
        let button = controller.form.submit
        button.scrollToVisible(button.bounds)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(window.contentView).bounds.height, 700)
        XCTAssertGreaterThan(button.visibleRect.height, 0, "The real conversion action must be visible in the test window.")
        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier,
                       ProcessInfo.processInfo.processIdentifier)
        await fulfillment(of: [completed], timeout: 240)
        XCTAssertNil(conversionError)
        let result = try XCTUnwrap(converted, conversionError ?? "No conversion result")
        let snapshot = try result.snapshot()
        XCTAssertEqual(snapshot.engine, engine, "No fallback may hide failure of the selected primary voice.")
        if engine == TtsSelection.edgeEngine { XCTAssertEqual(snapshot.voice, "pt-BR-FranciscaNeural") }
        let chapter = try XCTUnwrap(snapshot.chapterProgress?.first)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: try XCTUnwrap(chapter.downloadUrl)))
        XCTAssertGreaterThan(audio.length, 0)
        print("MAC_CONVERT_GUI engine=\(engine) job=\(result.jobID) frames=\(audio.length) output=\(result.outputDirectory.path)")
        // Allow the Convert screen to record its completed job before closing its window.
        for _ in 0..<40 where library.books.first?.lastJobId == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(library.books.first?.lastJobId)
        if engine == TtsSelection.systemEngine {
            let notices = descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSTextField }
            XCTAssertFalse(notices.contains { $0.stringValue == L10n.string("conversion.systemVoiceFallback") },
                           "An explicitly selected system primary must not appear as a fallback.")
        }
        // Keep the completed conversion visible for visual inspection and window capture.
        window.contentView?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 10_000_000_000)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier,
                       ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(window.occlusionState.contains(.visible))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(window.contentView).bounds.height, 700)
    }
    #endif

    func runtimeAdapter() throws -> ConverterFFIAdapter {
        #if APP_FOUNDATION_HOST_TESTS
        guard let path = ProcessInfo.processInfo.environment["APP_FOUNDATION_FFI_LIBRARY"] else {
            throw XCTSkip("Run apple:foundation:ffi:test for the real host dylib boundary.")
        }
        return ConverterFFIAdapter(libraryURL: URL(fileURLWithPath: path))
        #else
        return ConverterFFIAdapter()
        #endif
    }







    final class ObservedSupportManager: FileManager, @unchecked Sendable {
        let root: URL
        var supportLookups = 0
        init(root: URL) { self.root = root; super.init() }
        override func url(for directory: SearchPathDirectory, in domain: SearchPathDomainMask,
                          appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
            supportLookups += 1
            return root
        }
    }



    #if os(iOS) && targetEnvironment(simulator)

    #endif




    #if APP_FOUNDATION_HOST_TESTS

    #endif
}

#if APP_FOUNDATION_HOST_TESTS
final class FFIChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(chapter: Int, index: Int, bytes: Data)] = []

    func append(chapter: Int, index: Int, bytes: Data) {
        lock.lock()
        values.append((chapter, index, bytes))
        lock.unlock()
    }

    func snapshot() -> [(chapter: Int, index: Int, bytes: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
#endif
