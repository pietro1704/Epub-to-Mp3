import XCTest
@testable import EpubToMp3

final class ConvertViewModelTests: XCTestCase {
    private func manualResult(jobID: String = "manual-only") -> RustConversionCoordinator.Result {
        .init(jobID: jobID, manifestJSON: Data("{\"manifest\":{\"jobId\":\"\(jobID)\",\"title\":\"Fixture\",\"author\":\"Author\",\"chapters\":[]}}".utf8),
              outputDirectory: URL(fileURLWithPath: "/unused-manual-output"))
    }

    @MainActor
    func testDefaultExecutorRejectsUnsupportedProviderBeforeOpeningBook() async {
        let model = ConvertViewModel()
        model.selectedFile = URL(fileURLWithPath: "/must-not-open-unsupported-provider.epub")
        model.engine = "coqui"
        await model.submit()
        XCTAssertTrue(model.error?.contains("unsupported conversion engine") == true,
                      "Default form executor did not validate its explicit options: \(model.error ?? "no error")")
        XCTAssertNil(model.submittedJobId)
        XCTAssertFalse(model.isSubmitting)
    }

    @MainActor
    func testManualSuccessLeavesPlaybackSnapshotUnchanged() async throws {
        let result = manualResult()
        let model = ConvertViewModel(converter: { _, _, _, _ in result })
        model.selectedFile = URL(fileURLWithPath: "/unused-manual-input.epub")
        let suite = "manual-playback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        player.setSnapshot(try manualResult(jobID: "already-paused").snapshot())
        let previous = player.snapshot
        await model.submit(player: player)
        XCTAssertEqual(player.snapshot, previous)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testManualFormForwardsConfigurationAndDoesNotMutatePlayback() async throws {
        var captured: ConversionOptions?
        var capturedBounds: (Int32, Int32)?
        let result = manualResult()
        let model = ConvertViewModel(converter: { _, start, end, options in
            captured = options
            capturedBounds = (start, end)
            return result
        })
        model.selectedFile = URL(fileURLWithPath: "/unused-manual-input.epub")
        model.engine = "piper"
        model.voice = "speaker-0"
        model.language = "pt-BR"
        model.clearCache = true
        model.forceReprocess = true
        model.maxPerformance = true
        model.chapters = "8-9"
        let suite = "manual-conversion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let previous = player.snapshot
        await model.submit(player: player)
        XCTAssertEqual(captured, ConversionOptions(engine: "piper", voice: "speaker-0", language: "pt-BR",
                                                  clearCache: true, forceReprocess: true, maxPerformance: true))
        XCTAssertEqual(capturedBounds?.0, 8)
        XCTAssertEqual(capturedBounds?.1, 9)
        XCTAssertEqual(model.submittedJobId, "manual-only")
        XCTAssertNil(model.error)
        XCTAssertEqual(player.snapshot, previous)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testChapterSelectionRejectsMalformedInputInsteadOfSelectingWholeBook() throws {
        for input in ["invalid", "8-", "-1", "9-8", "8-9-10", "2147483648", "8-bad-9"] {
            XCTAssertThrowsError(try ConvertViewModel.parseChapterSelection(input), "Accepted malformed selection: \(input)")
        }
        let single = try ConvertViewModel.parseChapterSelection("8")
        XCTAssertEqual(single.start, 8)
        XCTAssertEqual(single.end, 8)
        let range = try ConvertViewModel.parseChapterSelection(" 8 - 9 ")
        XCTAssertEqual(range.start, 8)
        XCTAssertEqual(range.end, 9)
        let whole = try ConvertViewModel.parseChapterSelection("   ")
        XCTAssertEqual(whole.start, -1)
        XCTAssertEqual(whole.end, -1)
    }

    @MainActor
    func testMissingClientAndFileProduceActionableErrors() async {
        let model = ConvertViewModel()

        await model.submit(client: nil)
        XCTAssertEqual(model.error, L10n.string("convert.error.pickFileFirst"))

        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:1")!)
        model.error = nil
        await model.submit(client: client)
        XCTAssertEqual(model.error, L10n.string("convert.error.pickFileFirst"))
    }

#if os(macOS)
    @MainActor
    func testImportForConversionCopiesIntoOwnedInbox() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("convert-(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Book.epub")
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try Data("epub".utf8).write(to: source)

        let copied = try ConvertViewModel.importForConversion(source, baseDirectory: inbox)

        XCTAssertNotEqual(copied.standardizedFileURL, source.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: copied), Data("epub".utf8))
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
    }
#endif
}
