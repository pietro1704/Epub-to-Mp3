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

    func testPlaybackAsksRustWithTheBookVoiceAndAppliesItWithoutALanguage() async throws {
        let suite = "book-voice-playback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(faber)
        settings.bookVoices.set(cadu, bookID: suite)
        let book = BookEntity(id: suite, title: "Book", bookmark: Data([1]), displayFilename: "book.epub", addedAt: Date())
        var asked: [TtsSelection?] = []
        func dependencies(language: String?) -> LanguageModelPlayback.Dependencies {
            .init(bookLanguage: { _ in language }, resolve: { request in
                      asked.append(request.bookVoice)
                      return LanguageModelResolution(bookLanguage: request.bookLanguage, status: .selected,
                          selection: request.bookVoice, source: .bookVoice, reasons: [], missing: nil)
                  }, installedModelIDs: { [] }, systemVoiceLanguages: { [] })
        }
        for language in ["pt", nil] {
            let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
                                                              dependencies: dependencies(language: language))
            guard case let .use(preferences) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertEqual(preferences.primary, cadu)
        }
        XCTAssertEqual(asked, [cadu])
    }

    func testGoingBackToTheDefaultDropsTheBookVoiceAndRestarts() async throws {
        let suite = "book-voice-default-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(faber)
        let book = BookEntity(id: suite, title: "Book", bookmark: Data([1]), displayFilename: "book.epub", addedAt: Date())
        var restarted: [TtsSelection?] = []
        var request = ReaderVoicePickerRequest(settings: settings, library: LibraryStore(defaults: defaults),
            player: AudioPlayer(),
            currentContext: { .init(book: book, startingPosition: .init(chapter: 0, pageRatio: 0, seek: nil, autoplay: true)) },
            restart: { _, options in restarted.append(options.ttsPreferences?.primary) })
        request.dependencies = .init(bookLanguage: { _ in nil }, resolve: { _ in throw EmbeddedConverterError.artifactUnavailable },
                                     installedModelIDs: { [] }, systemVoiceLanguages: { [] })
        XCTAssertNil(try XCTUnwrap(request.picker()).useDefault, "Nothing to go back from")
        settings.bookVoices.set(cadu, bookID: suite)

        let useDefault = try XCTUnwrap(try XCTUnwrap(request.picker()).useDefault)
        await useDefault()

        XCTAssertNil(settings.bookVoices.voice(bookID: suite))
        XCTAssertEqual(restarted, [faber])
    }
}
