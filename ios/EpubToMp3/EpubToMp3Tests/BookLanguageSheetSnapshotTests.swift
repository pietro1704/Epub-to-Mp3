#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// Renders the macOS book language sheet into PNGs for the PR's visual evidence.
/// It only writes files when EPUB2MP3_MODELS_SNAPSHOT_DIR (or its marker file) is set.
@MainActor
final class BookLanguageSheetSnapshotTests: XCTestCase {
    func testRenderTheSheetWithDetectionAndConflict() async throws {
        guard let directory = ProcessInfo.processInfo.environment["EPUB2MP3_MODELS_SNAPSHOT_DIR"]
            ?? (try? String(contentsOfFile: "/tmp/epub2mp3-models-snapshot-dir", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw XCTSkip("Set EPUB2MP3_MODELS_SNAPSHOT_DIR to render") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let json = """
        {"declared":"en-US","confirmed":null,"languages":[],"samples_examined":1,"inconclusive_samples":0,\
        "profile":{"class":"monolingual","primary":"pt","incidental":["fr","la"],\
        "languages":[{"language":"pt","chars":980,"fraction":0.98,"longest_section_chars":980}]}}
        """
        let analysis = try JSONDecoder().decode(BookLanguageAnalysis.self, from: Data(json.utf8))
        let detected = try XCTUnwrap(BookLanguageSheetSummary(analysis: analysis)).text
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let (alert, _, _) = BookLanguagePicker.makeMacAlert(
                allowsAutomatic: true, selectedLanguage: nil,
                explanation: detected + "\n\n" + L10n.string("language.correctionHelp"),
                tags: ["pt", "pt-BR", "en", "es"])
            alert.window.appearance = NSAppearance(named: appearance)
            alert.window.isReleasedWhenClosed = false
            alert.layout()
            alert.window.center()
            alert.window.orderFront(nil)
            for _ in 0..<20 { try await Task.sleep(nanoseconds: 50_000_000) }
            let image = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow,
                CGWindowID(alert.window.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("book-language-sheet-\(name).png"))
            alert.window.close()
        }
    }
}
#endif
