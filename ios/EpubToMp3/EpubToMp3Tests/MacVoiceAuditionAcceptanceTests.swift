#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacVoiceAuditionAcceptanceTests: XCTestCase {
    func testOptInInstalledFaberAuditionAndCancellationUseIndependentNativePlayback() async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_MODEL_INSTALL_ACCEPTANCE"] == "1",
              let source = ProcessInfo.processInfo.environment["TTS_TEST_INSTALLED_MODELS_ROOT"] else {
            throw XCTSkip("Requires the explicitly authorized isolated Faber installation")
        }
        let root = URL(fileURLWithPath: source)
        try mark("probing", root: root)
        XCTAssertNotEqual(root.standardizedFileURL, LocalSpeechModelReadiness.ttsModelsRoot()?.standardizedFileURL)
        let current = SpeechModelLibraryTarget.current()
        let target = SpeechModelLibraryTarget(language: "pt-BR", platform: current.platform,
            androidAPI: current.androidAPI, architecture: current.architecture,
            osVersion: current.osVersion, modelsRoot: root)
        let snapshot = try ConverterFFIAdapter().speechModelSnapshot(target: target, probeRuntime: true)
        let state = SpeechModelLibraryViewState(snapshot: snapshot)
        let entry = try XCTUnwrap(state.entries.first { $0.identity.modelID == "pt_BR-faber-medium" })
        XCTAssertEqual(entry.installation.state, .installed)
        XCTAssertEqual(entry.readiness.state, .ready, entry.readiness.failure ?? "Runtime probe did not report readiness")
        let selection = try XCTUnwrap(state.selection(for: entry))
        try mark("ready", root: root)
        let settings = AppSettings()
        let settingsBefore = settings.ttsPreferences
        let readingBefore = UserDefaults.standard.string(forKey: "currentlyReadingBookID")
        let controller = VoiceAuditionController(modelsRoot: root)
        defer { controller.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 350),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        // Swift owns this fixture; closing must not also release its instance.
        window.isReleasedWhenClosed = false
        window.title = "Faber — isolated native audition"
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        defer {
            try? mark("closing-window", root: root)
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
            try? mark("window-closed", root: root)
        }
        let presentation = VoiceAuditionPresentation(audition: controller)
        presentation.present(selection: selection, language: "pt-BR", on: window)
        try await waitUntil(controller) { controller.state == .playing }
        XCTAssertEqual(controller.state, .playing, "Actual embedded Faber must produce playable MP3")
        try mark("playing", root: root)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        content.layoutSubtreeIfNeeded()
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "actual-faber-audition-playing"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        try await waitUntil(controller) { controller.state == .idle }
        try mark("finished", root: root)
        XCTAssertEqual(settings.ttsPreferences, settingsBefore)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "currentlyReadingBookID"), readingBefore)
        window.endSheet(sheet)
        try await waitUntil(controller) { window.attachedSheet == nil }
        try mark("sheet-dismissed", root: root)
        XCTAssertEqual(controller.state, .idle)
        let cancelled = controller.start(selection: selection, language: "pt-BR")
        await Task.yield()
        controller.stop()
        await cancelled.value
        try mark("cancelled", root: root)
        XCTAssertEqual(controller.state, .idle)
    }

    private func waitUntil(_ controller: VoiceAuditionController, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            if case .failed(let message) = controller.state {
                throw EmbeddedConverterError.conversionFailed(message)
            }
            guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func mark(_ phase: String, root: URL) throws {
        let file = root.deletingLastPathComponent().appendingPathComponent("audition-milestones.log")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(Date().timeIntervalSince1970) \(phase)\n".utf8))
        try handle.synchronize()
    }
}
#endif
