import XCTest
@testable import EpubToMp3

/// A4: a voice picked in the reader belongs to that book; it never rewrites the global or per-language choices.
@MainActor
final class BookVoiceOverrideTests: XCTestCase {
    private let faber = TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil)
    private let cadu = TtsSelection(engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil)

    func testAReaderPickRestartsWithTheVoiceAndLeavesTheGlobalAndLanguageChoicesAlone() throws {
        let suite = "book-voice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(faber)
        let book = BookEntity(id: suite, title: "Book", bookmark: Data([1]), displayFilename: "book.epub", addedAt: Date())
        var restarted: [TtsSelection?] = []
        let request = ReaderVoicePickerRequest(settings: settings, library: LibraryStore(defaults: defaults),
            player: AudioPlayer(),
            currentContext: { .init(book: book, startingPosition: .init(chapter: 0, pageRatio: 0, seek: nil, autoplay: true)) },
            restart: { _, options in restarted.append(options.ttsPreferences?.primary) })
        let picker = try XCTUnwrap(request.picker())
        let content = ReaderModelSwitch.content(language: "pt", rows: [], picker: picker)

        content.choose(cadu, picker: picker, settings: settings)

        XCTAssertEqual(restarted, [cadu], "Playback restarts at once with the picked voice")
        XCTAssertEqual(settings.primaryTtsSelection, faber, "The global primary is not rewritten")
        XCTAssertNil(settings.languageModelChoices["pt"], "The language's voice is not rewritten")
        XCTAssertEqual(try XCTUnwrap(request.picker()).selection, cadu, "The book keeps the picked voice")
    }
}
