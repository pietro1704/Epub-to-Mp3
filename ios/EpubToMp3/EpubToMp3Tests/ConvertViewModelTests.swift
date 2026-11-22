import XCTest
@testable import EpubToMp3

final class ConvertViewModelTests: XCTestCase {
    // MARK: - Source identity for language recovery
    //
    // The security scope taken for the conversion ends when ConvertViewModel.submit returns.
    // The language recovery then hashes the picked file; a file picked in place (Files, iCloud,
    // asCopy: false) is unreadable without its own scope, so the hash failed and the recovery
    // picker never appeared.

    private struct ScopeTrace {
        var events: [String] = []
    }

    func testSourceIdentityHashesInsideItsOwnSecurityScope() throws {
        let file = URL(fileURLWithPath: "/tmp/picked.epub")
        var trace = ScopeTrace()
        let identity = try ConvertViewModel.sourceIdentity(
            of: file,
            startScope: { _ in trace.events.append("start"); return true },
            stopScope: { _ in trace.events.append("stop") },
            hash: { _ in trace.events.append("hash"); return "identity" })
        XCTAssertEqual(identity, "identity")
        XCTAssertEqual(trace.events, ["start", "hash", "stop"])
    }

    func testSourceIdentityClosesTheScopeWhenHashingFails() {
        let file = URL(fileURLWithPath: "/tmp/picked.epub")
        var trace = ScopeTrace()
        XCTAssertThrowsError(try ConvertViewModel.sourceIdentity(
            of: file,
            startScope: { _ in trace.events.append("start"); return true },
            stopScope: { _ in trace.events.append("stop") },
            hash: { _ in trace.events.append("hash"); throw CocoaError(.fileReadNoPermission) }))
        XCTAssertEqual(trace.events, ["start", "hash", "stop"])
    }

    func testSourceIdentityNeverClosesAScopeItDidNotOpen() throws {
        let file = URL(fileURLWithPath: "/tmp/inside-the-app.epub")
        var trace = ScopeTrace()
        _ = try ConvertViewModel.sourceIdentity(
            of: file,
            startScope: { _ in trace.events.append("start"); return false },
            stopScope: { _ in trace.events.append("stop") },
            hash: { _ in trace.events.append("hash"); return "identity" })
        XCTAssertEqual(trace.events, ["start", "hash"], "a file the app already owns has no scope to stop")
    }

#if os(macOS)
    private final class PartialCopyFailureFileManager: FileManager, @unchecked Sendable {
        override func copyItem(at source: URL, to destination: URL) throws {
            try Data("Partial copy".utf8).write(to: destination)
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        }
    }

    private func withConversionInbox(
        _ body: (URL, URL, URL) throws -> Void
    ) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("convert-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let source = root.appendingPathComponent("Book.epub")
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try Data("Original selected source".utf8).write(to: source)
        try body(root, inbox, source)
    }
#endif

    private func manualResult(jobID: String = "manual-only") -> RustConversionCoordinator.Result {
        .init(jobID: jobID, manifestJSON: Data("{\"manifest\":{\"jobId\":\"\(jobID)\",\"title\":\"Fixture\",\"author\":\"Author\",\"chapters\":[]}}".utf8),
              outputDirectory: URL(fileURLWithPath: "/unused-manual-output"))
    }

    @MainActor
    func testCompatibleRecoveryAddsSecondaryOnlyForRetryWithoutChangingSavedPreferences() async throws {
        var captured: ConversionOptions?
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, options, _, _ in
            captured = options
            return self.manualResult(jobID: jobID)
        }))
        let preferences = TtsPreferences(primary: .defaultPiper, secondary: nil, allowOnlineFallback: false)
        let candidate = TtsRecoveryCandidate(name: "English", selection: TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil))
        model.selectedFile = URL(fileURLWithPath: "/fixture.pdf")
        model.inheritedPreferences = preferences
        model.recoverySelection = candidate
        model.recoveryLanguage = "en-US"
        await model.submit()
        XCTAssertEqual(captured?.ttsPreferences?.primary, preferences.primary)
        XCTAssertEqual(captured?.ttsPreferences?.secondary, candidate.selection)
        XCTAssertNil(captured?.language)
        XCTAssertEqual(model.inheritedPreferences, preferences)
        XCTAssertNil(model.recoverySelection)
        await model.submit()
        XCTAssertEqual(captured?.ttsPreferences, preferences)
        XCTAssertNil(captured?.language)
    }

    @MainActor
    func testDefaultExecutorRejectsUnsupportedProviderBeforeOpeningBook() async {
        let model = ConvertViewModel()
        model.selectedFile = URL(fileURLWithPath: "/must-not-open-unsupported-provider.epub")
        model.engine = "coqui"
        await model.submit()
        XCTAssertEqual(model.error,
                       EmbeddedConverterError.conversionFailed("Unsupported TTS engine: coqui").errorDescription,
                       "The typed provider policy must reject the literal engine before opening the book")
        XCTAssertNil(model.submittedJobId)
        XCTAssertFalse(model.isSubmitting)
    }

    @MainActor
    func testManualSuccessLeavesPlaybackSnapshotUnchanged() async throws {
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, _, _, _ in
            self.manualResult(jobID: jobID)
        }))
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
    func testRepeatedManualSubmitDoesNotStartAnotherConversionWhileFirstIsPending() async {
        var release: AsyncStream<Void>.Continuation!
        let gate = AsyncStream<Void> { release = $0 }
        let started = expectation(description: "First conversion suspended")
        let retried = expectation(description: "Second submit intent delivered")
        var calls = 0
        var requestedJobID: String?
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, _, _, _ in
            requestedJobID = jobID
            calls += 1
            if calls == 1 { started.fulfill() }
            for await _ in gate { }
            return self.manualResult(jobID: jobID)
        }))
        model.selectedFile = URL(fileURLWithPath: "/unused-manual-input.epub")
        let first = Task { await model.submit() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isSubmitting)
        let second = Task { retried.fulfill(); await model.submit() }
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertEqual(calls, 1, "Repeated manual intent must not enqueue another Rust conversion")
        XCTAssertTrue(model.isSubmitting)
        release.finish()
        await first.value
        await second.value
        XCTAssertNotNil(requestedJobID)
        XCTAssertEqual(model.submittedJobId, requestedJobID)
        XCTAssertFalse(model.isSubmitting)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testInheritedExplicitModelRemainsCapturedWhenPreferencesChangeDuringJob() async {
        let selected = TtsPreferences(
            primary: TtsSelection(engine: "piper", modelID: "pt_BR-edresson-low", voice: "speaker-0"),
            secondary: nil, allowOnlineFallback: false
        )
        var captured: ConversionOptions?
        let started = expectation(description: "Explicit model job captured its options")
        var release: AsyncStream<Void>.Continuation!
        let gate = AsyncStream<Void> { release = $0 }
        defer { release.finish() }
        var requestedJobID: String?
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, options, _, _ in
            requestedJobID = jobID
            captured = options
            started.fulfill()
            for await _ in gate {}
            return self.manualResult(jobID: jobID)
        }))
        model.selectedFile = URL(fileURLWithPath: "/unused-explicit-model.epub")
        model.modelsRoot = "/owned-fixture-models"
        model.engine = "edge"
        model.voice = "must-not-replace-captured-voice"
        model.language = "pt-BR"
        model.inheritedPreferences = selected
        model.usesPreferences = true
        let pending = Task { await model.submit() }
        await fulfillment(of: [started], timeout: 2)
        model.inheritedPreferences = TtsPreferences(
            primary: .defaultPiper, secondary: nil, allowOnlineFallback: false
        )
        release.finish()
        await pending.value
        var expected = ConversionOptions(
            engine: "piper", voice: "speaker-0", language: "pt-BR",
            modelsRoot: "/owned-fixture-models", modelID: "pt_BR-edresson-low",
            espeakDataDirectory: Bundle.main.resourceURL?.path
        )
        expected.ttsPreferences = selected
        XCTAssertEqual(captured, expected)
        XCTAssertEqual(model.inheritedPreferences?.primary.modelID, "pt_BR-faber-medium")
        XCTAssertNotNil(requestedJobID)
        XCTAssertEqual(model.submittedJobId, requestedJobID)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testManualFormForwardsConfigurationAndDoesNotMutatePlayback() async throws {
        var captured: ConversionOptions?
        var capturedBounds: (Int32, Int32)?
        var requestedJobID: String?
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, start, end, options, _, _ in
            requestedJobID = jobID
            captured = options
            capturedBounds = (start, end)
            return self.manualResult(jobID: jobID)
        }))
        model.selectedFile = URL(fileURLWithPath: "/unused-manual-input.epub")
        let modelsRoot = try XCTUnwrap(LocalSpeechModelReadiness.ttsModelsRoot()).path
        model.modelsRoot = modelsRoot
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
        var expected = ConversionOptions(engine: "piper", voice: "speaker-0", language: "pt-BR",
                                         clearCache: true, forceReprocess: true, maxPerformance: true,
                                         modelsRoot: modelsRoot, modelID: "pt_BR-faber-medium",
                                         espeakDataDirectory: Bundle.main.resourceURL?.path)
        expected.ttsPreferences = TtsPreferences(
            primary: TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: "speaker-0"),
            secondary: nil, allowOnlineFallback: false
        )
        XCTAssertEqual(captured, expected)
        XCTAssertEqual(model.manualPrimary, expected.ttsPreferences?.primary)
        XCTAssertEqual(capturedBounds?.0, 8)
        XCTAssertEqual(capturedBounds?.1, 9)
        XCTAssertNotNil(requestedJobID)
        XCTAssertEqual(model.submittedJobId, requestedJobID)
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
    func testMissingFileProducesActionableError() async {
        let model = ConvertViewModel()

        await model.submit()
        XCTAssertEqual(model.error, L10n.string("convert.error.pickFileFirst"))
    }

#if os(macOS)
    @MainActor
    func testImportSuccessPreservesPriorInboxInputsWithSameFilename() throws {
        try withConversionInbox { _, inbox, source in
            let first = try ConvertViewModel.importForConversion(source, baseDirectory: inbox)
            let original = try Data(contentsOf: first)
            let next = Data("Next selected source".utf8)
            try next.write(to: source)

            let second = try ConvertViewModel.importForConversion(source, baseDirectory: inbox)

            XCTAssertNotEqual(first.standardizedFileURL, second.standardizedFileURL)
            XCTAssertEqual(try Data(contentsOf: first), original)
            XCTAssertEqual(try Data(contentsOf: second), next)
            XCTAssertEqual(try Data(contentsOf: source), next)
        }
    }

    @MainActor
    func testPartialCopyFailurePreservesPriorInboxInputsAndSource() throws {
        try withConversionInbox { _, inbox, source in
            let prior = try ConvertViewModel.importForConversion(source, baseDirectory: inbox)
            let priorBytes = try Data(contentsOf: prior)
            let unrelated = inbox.appendingPathComponent("Other.epub")
            let unrelatedBytes = Data("Another pending input".utf8)
            try unrelatedBytes.write(to: unrelated)
            let entries = try FileManager.default.contentsOfDirectory(atPath: inbox.path).sorted()
            let sourceBytes = Data("Source for failed import".utf8)
            try sourceBytes.write(to: source)

            XCTAssertThrowsError(try ConvertViewModel.importForConversion(
                source, fileManager: PartialCopyFailureFileManager(), baseDirectory: inbox
            ))

            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path).sorted(), entries,
                           "Failed staging must leave no partial copy or remove any prior input")
            XCTAssertEqual(try Data(contentsOf: prior), priorBytes)
            XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedBytes)
        }
    }

    @MainActor
    func testImportFromInboxPreservesSourceAndOtherInputs() throws {
        try withConversionInbox { _, inbox, source in
            let prior = try ConvertViewModel.importForConversion(source, baseDirectory: inbox)
            let priorBytes = try Data(contentsOf: prior)
            let unrelated = inbox.appendingPathComponent("Other.epub")
            let unrelatedBytes = Data("Another pending input".utf8)
            try unrelatedBytes.write(to: unrelated)

            let copied = try ConvertViewModel.importForConversion(prior, baseDirectory: inbox)

            XCTAssertNotEqual(copied.standardizedFileURL, prior.standardizedFileURL)
            XCTAssertEqual(try Data(contentsOf: copied), priorBytes)
            XCTAssertEqual(try Data(contentsOf: prior), priorBytes)
            XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedBytes)
            XCTAssertEqual(try Data(contentsOf: source), Data("Original selected source".utf8))
        }
    }

    @MainActor
    func testImportForConversionCopiesIntoOwnedInbox() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("convert-\(UUID().uuidString)", isDirectory: true)
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
