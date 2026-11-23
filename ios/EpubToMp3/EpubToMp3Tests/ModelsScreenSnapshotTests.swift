#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// Renders the macOS Models screen with a fake catalog into PNGs for the PR's visual
/// evidence: a download in progress, a chosen model and the dimmed rows, in light and
/// dark. It only writes files when EPUB2MP3_MODELS_SNAPSHOT_DIR is set.
@MainActor
final class ModelsScreenSnapshotTests: XCTestCase {
    func testRenderDownloadProgressAndChoiceInLightAndDark() async throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["EPUB2MP3_MODELS_SNAPSHOT_DIR"]
            ?? (try? String(contentsOfFile: "/tmp/epub2mp3-models-snapshot-dir", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines), "Set EPUB2MP3_MODELS_SNAPSHOT_DIR to render")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let source = ModelsByLanguageModelTests.FakeSource()
            let suite = "models-snapshot-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            settings.selectLanguageModel(TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil), for: "pt")
            let controller = MacModelsViewController(settings: settings, source: source,
                                                     termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = controller
            window.makeKeyAndOrderFront(nil)
            window.setContentSize(NSSize(width: 760, height: 620))
            controller.view.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
            controller.view.autoresizingMask = [.width, .height]
            controller.view.layoutSubtreeIfNeeded()
            for _ in 0..<60 { try await Task.sleep(nanoseconds: 50_000_000) }
            // Tap the dimmed Cadu row (the table's click path), then report 40%.
            let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
            let rowIndex = try XCTUnwrap((0..<table.numberOfRows).first { index in
                descendants(table.view(atColumn: 0, row: index, makeIfNecessary: true) ?? NSView())
                    .contains { $0.accessibilityIdentifier() == "models.row.pt.piper:pt_BR-cadu-medium" }
            })
            controller.activateRow(at: rowIndex)
            for _ in 0..<20 { try await Task.sleep(nanoseconds: 50_000_000) }
            source.emit("pt_BR-cadu-medium", .downloading, done: 40)
            for _ in 0..<40 { try await Task.sleep(nanoseconds: 50_000_000) }
            window.layoutIfNeeded()
            let png = try windowPNG(window)
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("download-progress-\(name).png"))
            window.contentViewController = nil
            window.close()
        }
    }

    /// The window as the screen shows it (controls and vibrancy included); falls back to the view cache.
    private func windowPNG(_ window: NSWindow) throws -> Data {
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                               [.boundsIgnoreFraming, .bestResolution]) {
            let rep = NSBitmapImageRep(cgImage: image)
            if let png = rep.representation(using: .png, properties: [:]) { return png }
        }
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
