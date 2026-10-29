#if os(macOS)
import AppKit
import AVFoundation
import CryptoKit
import XCTest
@testable import EpubToMp3

private struct PiperComparisonRender: @unchecked Sendable {
    let adapter: ConverterFFIAdapter
    let control: ConverterPlaybackControl
    let options: ConversionOptions
    let output: URL
    let text: String
    func run() throws { try adapter.audition(text: text, options: options, output: output, control: control) }
}

/// Opt-in real inference and audible playback of the same passage, without fallback.
@MainActor
final class MacPiperVoiceComparisonTests: XCTestCase {
    func testInstalledFaberCaduAndJeffRenderAndPlayTheSamePassage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPUB2MP3_MODEL_INSTALL_ACCEPTANCE"] == "3",
              let path = environment["TTS_TEST_INSTALLED_MODELS_ROOT"] else {
            throw XCTSkip("Requires explicit three-voice audible acceptance and installed models")
        }
        let root = URL(fileURLWithPath: path)
        XCTAssertNotEqual(root.standardizedFileURL, LocalSpeechModelReadiness.ttsModelsRoot()?.standardizedFileURL)
        let output = root.deletingLastPathComponent().appendingPathComponent("voice-comparison-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let text = "O Sr. Antônio chegou às 8h30. — Você trouxe o livro? — Sim! Custou R$ 12,50. Ela sorriu, abriu a janela e começou a ler: era uma manhã tranquila."
        let settingsBefore = AppSettings().ttsPreferences
        let readingBefore = UserDefaults.standard.string(forKey: "currentlyReadingBookID")
        defer {
            XCTAssertEqual(AppSettings().ttsPreferences, settingsBefore)
            XCTAssertEqual(UserDefaults.standard.string(forKey: "currentlyReadingBookID"), readingBefore)
        }
        let current = SpeechModelLibraryTarget.current()
        let target = SpeechModelLibraryTarget(language: "pt-BR", platform: current.platform,
            androidAPI: current.androidAPI, architecture: current.architecture,
            osVersion: current.osVersion, modelsRoot: root)
        let snapshot = try ConverterFFIAdapter().speechModelSnapshot(target: target, probeRuntime: true)
        let state = SpeechModelLibraryViewState(snapshot: snapshot)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 350),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Piper — Faber / Cadu / Jeff — same passage"
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        defer { window.close() }
        var reports: [[String: Any]] = []
        for modelID in ["pt_BR-faber-medium", "pt_BR-cadu-medium", "pt_BR-jeff-medium"] {
            let entry = try XCTUnwrap(state.entries.first { $0.identity.modelID == modelID })
            XCTAssertEqual(entry.installation.state, .installed)
            XCTAssertEqual(entry.readiness.state, .ready, entry.readiness.failure ?? modelID)
            let selection = try XCTUnwrap(state.selection(for: entry))
            let audio = output.appendingPathComponent("\(modelID).mp3")
            let adapter = ConverterFFIAdapter()
            let control = try adapter.makePlaybackControl()
            var options = ConversionOptions(engine: "piper", language: "pt-BR", modelsRoot: root.path,
                modelID: modelID, espeakDataDirectory: Bundle.main.resourceURL?.path)
            options.ttsPreferences = TtsPreferences(primary: selection, secondary: nil, allowOnlineFallback: false)
            let render = PiperComparisonRender(adapter: adapter, control: control, options: options, output: audio, text: text)
            let started = Date()
            try await Task.detached(priority: .userInitiated) { try render.run() }.value
            let synthesisSeconds = Date().timeIntervalSince(started)
            let player = try AVAudioPlayer(contentsOf: audio)
            XCTAssertGreaterThan(player.duration, 0)
            let controller = VoiceAuditionController(renderer: { _, _ in audio })
            let presentation = VoiceAuditionPresentation(audition: controller)
            presentation.present(selection: selection, language: "pt-BR", on: window)
            defer { controller.stop() }
            try await waitUntil(controller) { controller.state == .playing }
            if let content = window.attachedSheet?.contentView,
               let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "same-passage-\(modelID)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            try await waitUntil(controller) { controller.state == .idle }
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            reports.append(["model_id": modelID, "text": text, "fallback": false,
                "mp3": audio.path, "duration_seconds": player.duration,
                "synthesis_seconds": synthesisSeconds,
                "sha256": SHA256.hash(data: try Data(contentsOf: audio)).map { String(format: "%02x", $0) }.joined()])
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("comparison.json"), options: .atomic)
    }

    private func waitUntil(_ controller: VoiceAuditionController, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            if case .failed(let message) = controller.state { throw EmbeddedConverterError.conversionFailed(message) }
            guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
#endif
