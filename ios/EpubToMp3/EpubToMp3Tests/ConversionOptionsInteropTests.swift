import Foundation
import XCTest
import AVFoundation
import ImageIO
import CryptoKit
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
    func testOptInMacConvertButtonUsesConfiguredEdgeAndProducesRealMP3() async throws {
        guard ProcessInfo.processInfo.environment["APP_FOUNDATION_LIVE_EDGE"] == "1" else {
            throw XCTSkip("Enable APP_FOUNDATION_LIVE_EDGE=1 for the visible macOS conversion journey.")
        }
        let source = try EpubFixture.createWithChapter(
            body: "Este pequeno capítulo valida a conversão pela janela do aplicativo.",
            includeCover: false, language: "pt-BR")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-edge-ui-\(UUID().uuidString)")
        let suite = "MacEdgeUI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let library = LibraryStore(defaults: defaults, importDirectory: root)
        let book = try library.importBook(from: source)
        let settings = AppSettings(defaults: defaults)
        settings.audioEngine = .edge
        settings.secondaryAudioEngine = nil
        let completed = expectation(description: "The real conversion submitted by the macOS button finishes")
        var converted: RustConversionCoordinator.Result?
        var conversionError: String?
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let controller = MacBookDetailViewController(book: book, library: library, settings: settings,
            player: player, playerPresentation: PlayerPresentation(defaults: defaults), onRead: { _ in }, onShowJobs: {},
            conversionExecutor: { url, job, first, last, options, progress, chapter in
                defer { completed.fulfill() }
                XCTAssertEqual(options?.ttsPreferences?.primary.engine, "edge")
                XCTAssertNil(options?.ttsPreferences?.secondary)
                do {
                    let result = try await RustConversionCoordinator.execute(
                        bookURL: url, jobID: job, chapterStart: first, chapterEnd: last,
                        options: options, onProgress: progress, onChapterCompleted: chapter)
                    converted = result
                    return result
                } catch {
                    conversionError = error.localizedDescription
                    throw error
                }
            })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Edge conversion validation — one chapter, no playback"
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "bookDetail.convert" })
        var accepted = false
        let dialog = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let modal = NSApp.modalWindow else { return }
                if !accepted {
                    accepted = true
                    NSApp.stopModal(withCode: .alertFirstButtonReturn)
                } else {
                    NSApp.abortModal()
                }
                modal.orderOut(nil)
            }
        }
        RunLoop.main.add(dialog, forMode: .modalPanel)
        defer {
            dialog.invalidate()
            window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        button.performClick(nil)
        XCTAssertTrue(accepted, "The actual Convert button must present its confirmation.")
        await fulfillment(of: [completed], timeout: 240)
        XCTAssertNil(conversionError)
        let result = try XCTUnwrap(converted, conversionError ?? "No conversion result")
        let snapshot = try result.snapshot()
        XCTAssertEqual(snapshot.engine, "edge", "No fallback may hide failure of the selected Edge voice.")
        XCTAssertEqual(snapshot.voice, "pt-BR-FranciscaNeural")
        let chapter = try XCTUnwrap(snapshot.chapterProgress?.first)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: try XCTUnwrap(chapter.downloadUrl)))
        XCTAssertGreaterThan(audio.length, 0)
        print("MAC_EDGE_GUI job=\(result.jobID) frames=\(audio.length) output=\(result.outputDirectory.path)")
        // Allow the real detail controller to publish its completed job before closing its window.
        for _ in 0..<40 where library.books.first?.lastJobId == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(library.books.first?.lastJobId)
    }
    #endif

    private func runtimeAdapter() throws -> ConverterFFIAdapter {
        #if APP_FOUNDATION_HOST_TESTS
        guard let path = ProcessInfo.processInfo.environment["APP_FOUNDATION_FFI_LIBRARY"] else {
            throw XCTSkip("Run apple:foundation:ffi:test for the real host dylib boundary.")
        }
        return ConverterFFIAdapter(libraryURL: URL(fileURLWithPath: path))
        #else
        return ConverterFFIAdapter()
        #endif
    }

    @MainActor
    func testOptInFaberStreamsFirstPlayableAudioAndPublishesOfflineChapters() async throws {
        guard let suppliedRoot = ProcessInfo.processInfo.environment["EPUB2MP3_PIPER_TEST_MODEL_ROOT"],
              !suppliedRoot.isEmpty, !suppliedRoot.contains("$("), !suppliedRoot.contains("${") else {
            throw XCTSkip("Set EPUB2MP3_PIPER_TEST_MODEL_ROOT to the existing original Faber model directory; this test never downloads voices.")
        }
        let fixtureRoot = URL(fileURLWithPath: suppliedRoot, isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("faber-inference-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let modelDirectory = models.appendingPathComponent("pt_BR-faber-medium", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = [
            (source: "pt_BR-faber-medium.onnx", target: "model.onnx", bytes: 63_201_294, hash: "858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7"),
            (source: "pt_BR-faber-medium.onnx.json", target: "model.onnx.json", bytes: 4_855, hash: "7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f"),
        ]
        for artifact in artifacts {
            let source = fixtureRoot.appendingPathComponent(artifact.source)
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            XCTAssertEqual(data.count, artifact.bytes, "The fixture must be the original catalog model.")
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), artifact.hash)
            let destination = modelDirectory.appendingPathComponent(artifact.target)
            do { try FileManager.default.linkItem(at: source, to: destination) }
            catch { try FileManager.default.copyItem(at: source, to: destination) }
        }
        let metadata: [String: Any] = ["id": "pt_BR-faber-medium", "artifacts": artifacts.map { ["path": $0.target, "sha256": $0.hash] }]
        try JSONSerialization.data(withJSONObject: metadata).write(to: modelDirectory.appendingPathComponent("metadata.json"))
        XCTAssertTrue(AppSettings.isFaberInstalled(modelsRoot: models))
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("espeak-ng-data/phontab").path),
                      "The real application must bundle eSpeak data before offline synthesis.")
        let book = try EpubFixture.createWithChapters([
            "Olá. Esta primeira página verifica a voz Faber em português. O áudio começa antes de terminar a conversão completa.",
            "Neste segundo capítulo, a mesma voz continua funcionando sem internet. Cada palavra deve produzir áudio válido e audível.",
        ])
        defer { try? FileManager.default.removeItem(at: book) }
        let adapter = try runtimeAdapter()
        let control = try adapter.makePlaybackControl()
        control.updatePlaybackWindow(currentChapter: 0, chaptersAhead: 1)
        var options = ConversionOptions.selectedEngine(.piper, modelsRoot: models)
        options.language = "pt-BR"
        options.espeakDataDirectory = resources.path
        options.ttsPreferences = TtsPreferences(primary: .selected(.piper), secondary: nil, allowOnlineFallback: false)
        let chunks = FaberInferenceEvidence()
        var providers: [RustConversionCoordinator.ConversionProgressEvent] = []
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await RustConversionCoordinator(adapter: adapter).convert(
            bookURL: book, chapterStart: 0, chapterEnd: 1, options: options, playbackControl: control,
            onProgress: { event in if event.modelId != nil { providers.append(event) } },
            onAudioChunk: { chapter, index, bytes in chunks.capture(chapter: chapter, index: index, bytes: bytes); return true }
        )
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let first = try XCTUnwrap(chunks.first())
        XCTAssertEqual(first.chapter, 0)
        XCTAssertEqual(first.index, 0)
        XCTAssertGreaterThan(chunks.count(), 1, "Both chapters must deliver playable segments.")
        XCTAssertLessThan(first.time - started, elapsed, "First playable audio must precede full conversion completion.")
        let firstURL = root.appendingPathComponent("first-chunk.mp3")
        try first.bytes.write(to: firstURL)
        let firstPeak = try assertNonSilentFullyDecodedAudio(firstURL)
        XCTAssertFalse(providers.isEmpty, "The real Rust worker must report the actual Faber model.")
        XCTAssertTrue(providers.allSatisfy { $0.engine == "piper" && $0.modelId == "pt_BR-faber-medium" && $0.fallbackUsed == false })
        let snapshot = try result.snapshot()
        XCTAssertEqual(snapshot.state, "finished")
        XCTAssertEqual(snapshot.engine, "piper")
        XCTAssertEqual(snapshot.voice, "pt_BR-faber-medium")
        let chapters = try XCTUnwrap(snapshot.chapterProgress)
        XCTAssertEqual(chapters.map(\.index), [0, 1])
        for chapter in chapters {
            let url = URL(fileURLWithPath: try XCTUnwrap(chapter.downloadUrl))
            XCTAssertTrue(url.path.hasSuffix(".mp3"))
            _ = try assertNonSilentFullyDecodedAudio(url)
        }
        print("FABER_NATIVE firstChunkSeconds=\(first.time - started) totalSeconds=\(elapsed) chunks=\(chunks.count()) firstPeak=\(firstPeak) engine=\(snapshot.engine ?? "") model=\(snapshot.voice ?? "") chapters=\(chapters.count)")
    }

    private func assertNonSilentFullyDecodedAudio(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> Float {
        let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertGreaterThan(audio.length, 0, file: file, line: line)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4_096), file: file, line: line)
        var decoded: AVAudioFramePosition = 0
        var peak: Float = 0
        var allFinite = true
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let samples = try XCTUnwrap(buffer.floatChannelData, file: file, line: line)
            for channel in 0..<Int(buffer.format.channelCount) {
                for index in 0..<Int(buffer.frameLength) {
                    let sample = samples[channel][index]
                    allFinite = allFinite && sample.isFinite
                    peak = max(peak, abs(sample))
                }
            }
            decoded += AVAudioFramePosition(buffer.frameLength)
        }
        XCTAssertTrue(allFinite, "Decoded audio samples must be finite.", file: file, line: line)
        XCTAssertEqual(decoded, audio.length, "The complete MP3 must decode, not merely its header.", file: file, line: line)
        XCTAssertGreaterThan(peak, 0.0001, "Synthesized speech must contain non-silent samples.", file: file, line: line)
        return peak
    }

    func testOptInSystemProviderPublishesPlayableMP3ThroughRust() async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_NATIVE_TTS_TEST"] == "1" else {
            throw XCTSkip("Enable EPUB2MP3_NATIVE_TTS_TEST=1 to exercise Apple PCM through Rust MP3 encoding.")
        }
        let source = try EpubFixture.createWithChapter(body: "Olá. Este pequeno capítulo testa a voz local.")
        defer { try? FileManager.default.removeItem(at: source) }
        let result = try await RustConversionCoordinator(adapter: runtimeAdapter()).convert(
            bookURL: source, options: ConversionOptions(engine: "system", language: "pt-BR")
        )
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let snapshot = try result.snapshot()
        let chapter = try XCTUnwrap(snapshot.chapterProgress?.first)
        let path = try XCTUnwrap(chapter.downloadUrl)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertTrue(path.hasSuffix(".mp3"))
    }

    func testOptInUnavailableEdgeVoiceFallsBackToSystemMP3() async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_NATIVE_TTS_TEST"] == "1" else {
            throw XCTSkip("Enable EPUB2MP3_NATIVE_TTS_TEST=1 for actual Edge failure and system fallback.")
        }
        let source = try EpubFixture.createWithChapter(body: "Olá. A voz local mantém este capítulo disponível.")
        defer { try? FileManager.default.removeItem(at: source) }
        let result = try await RustConversionCoordinator(adapter: runtimeAdapter()).convert(
            bookURL: source, options: ConversionOptions(
                engine: "edge", voice: "pt-BR-UnavailableFixtureVoice", language: "pt-BR"
            )
        )
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: result.manifestJSON) as? [String: Any])
        XCTAssertEqual(envelope["systemVoiceUsed"] as? Bool, true)
        let chapter = try XCTUnwrap(result.snapshot().chapterProgress?.first)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: try XCTUnwrap(chapter.downloadUrl)))
        XCTAssertGreaterThan(audio.length, 0)
    }

    func testFixtureCoverFullyDecodesAsPNG() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(EpubFixture.coverPNG as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(CGImageSourceGetStatus(source), .statusComplete)
    }

    func testChapterFixtureHasReadableSpineAndCoverInActualRustParser() throws {
        let source = try EpubFixture.createWithChapter()
        defer { try? FileManager.default.removeItem(at: source) }
        let metadata = try runtimeAdapter().openBook(at: source).metadataJSON
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        let chapters = try XCTUnwrap(fields["chapters"] as? [[String: Any]])
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(fields["title"] as? String, EpubFixture.title)
        // Rust validates the referenced cover while opening, unlike a metadata-
        // only fixture that can hide an empty spine or unresolved cover path.
    }

    func testExplicitModelConfigurationPreservesLiteralScopedPaths() throws {
        let options = ConversionOptions(engine: "piper", modelsRoot: "/app/tts-models",
                                        modelID: "pt_BR-edresson-low", modelPath: "model.onnx",
                                        modelConfigPath: "model.onnx.json",
                                        espeakDataDirectory: "/app/Resources")
        let data = Data(try options.encodedJSON().utf8)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fields["models_root"] as? String, "/app/tts-models")
        XCTAssertEqual(fields["model_id"] as? String, "pt_BR-edresson-low")
        XCTAssertEqual(fields["model_path"] as? String, "model.onnx")
        XCTAssertEqual(fields["model_config_path"] as? String, "model.onnx.json")
        XCTAssertEqual(fields["espeak_data_directory"] as? String, "/app/Resources")
        XCTAssertEqual(try JSONDecoder().decode(ConversionOptions.self, from: data), options)
    }

    func testScopedManifestRequiresExactOrderedChapterIdentities() throws {
        func result(_ indices: [Int?], jobID: String = "selected-job") throws -> RustConversionCoordinator.Result {
            let chapters: [[String: Any]] = indices.enumerated().map { offset, index in
                var chapter: [String: Any] = ["filename": "chapter-\(offset).mp3", "textChars": 42]
                if let index { chapter["sourceIndex"] = index }
                return chapter
            }
            let data = try JSONSerialization.data(withJSONObject: ["manifest": [
                "jobId": jobID, "title": "Fixture", "author": "Author", "chapters": chapters,
            ]])
            return .init(jobID: "selected-job", manifestJSON: data,
                         outputDirectory: URL(fileURLWithPath: "/unused-selection-output"))
        }
        try result([8, 9]).validateSelectedChapters(8...9)
        try result([8]).validateSelectedChapters(8...8)
        for indices: [Int?] in [[0, 1], [8, 8], [9, 8], [8], [8, 9, 10], [nil, nil], [8, nil]] {
            XCTAssertThrowsError(try result(indices).validateSelectedChapters(8...9), "Accepted \(indices)")
        }
        XCTAssertThrowsError(try result([8, 9], jobID: "different-job").validateSelectedChapters(8...9))
    }

    private final class ObservedSupportManager: FileManager, @unchecked Sendable {
        let root: URL
        var supportLookups = 0
        init(root: URL) { self.root = root; super.init() }
        override func url(for directory: SearchPathDirectory, in domain: SearchPathDomainMask,
                          appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
            supportLookups += 1
            return root
        }
    }

    func testCoordinatorRejectsInvalidOptionsBeforeBookOrOutputAccess() async throws {
        let adapter = try runtimeAdapter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ffi-coordinator-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ObservedSupportManager(root: directory)
        let coordinator = RustConversionCoordinator(adapter: adapter, fileManager: manager)
        do {
            _ = try await coordinator.convert(bookURL: URL(fileURLWithPath: "/must-not-open-book.epub"),
                                              options: ConversionOptions(engine: "coqui"))
            XCTFail("Unsupported provider unexpectedly accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsupported conversion engine"))
        }
        XCTAssertEqual(manager.supportLookups, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testExplicitPiperRequiresModelReadinessBeforeBookOrOutputAccess() async throws {
        let adapter = try runtimeAdapter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("piper-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ObservedSupportManager(root: directory)
        let coordinator = RustConversionCoordinator(adapter: adapter,
                                                     fileManager: manager)
        for options in [
            ConversionOptions(engine: "piper"),
            ConversionOptions(engine: "piper", modelsRoot: directory.path, modelID: "fixture",
                              modelPath: "model.onnx", modelConfigPath: "model.onnx.json"),
            ConversionOptions(engine: "edge", modelID: "must-not-ignore-model"),
        ] {
            do {
                _ = try await coordinator.convert(bookURL: URL(fileURLWithPath: "/must-not-open-unready-piper.epub"),
                                                  options: options)
                XCTFail("Unready or incompatible model configuration was accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.lowercased().contains("piper"), "Unexpected preflight error: \(error)")
            }
        }
        XCTAssertEqual(manager.supportLookups, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    #if os(iOS) && targetEnvironment(simulator)
    func testActualSimulatorFFIRejectsExplicitPiperWithoutInstalledModelBeforeBookOrOutputAccess() throws {
        let adapter = try runtimeAdapter()
        let input = URL(fileURLWithPath: "/must-not-open-piper-book.epub")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("must-not-create-piper-output-\(UUID().uuidString)")
        let options = ConversionOptions(
            engine: "piper", modelsRoot: "/must-not-read-piper-models",
            modelID: "pt_BR-edresson-low", modelPath: "model.onnx",
            modelConfigPath: "model.onnx.json"
        )

        XCTAssertThrowsError(try adapter.convertBook(
            at: input, outputDirectory: output, jobID: output.lastPathComponent,
            chapterStart: 0, chapterEnd: 0, options: options
        )) { error in
            XCTAssertTrue(
                error.localizedDescription.lowercased().contains("piper model"),
                "Unexpected missing-model result: \(error)"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testOptInPiperModelSynthesizesAndDecodesAudioOnSimulator() throws {
        guard ProcessInfo.processInfo.environment["APP_IOS_PIPER_INFERENCE"] == "1" else {
            throw XCTSkip("Set APP_IOS_PIPER_INFERENCE=1 to download the local Piper voice and run ONNX inference.")
        }
        let adapter = try runtimeAdapter()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("piper-models-\(UUID().uuidString)", isDirectory: true)
        let espeakData = try XCTUnwrap(Bundle.main.resourceURL)
            .appendingPathComponent("espeak-ng-data", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: espeakData.appendingPathComponent("phontab").path),
                      "The app bundle must include espeak-ng-data/phontab for local Piper synthesis.")
        let book = try EpubFixture.createWithChapter(body: "Olá. Esta é uma verificação de reprodução do Piper.")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("piper-output-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: book)
            try? FileManager.default.removeItem(at: output)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try adapter.installTtsModelFromCatalog(modelID: "pt_BR-edresson-low", root: root.path)
        let result = try adapter.convertBook(
            at: book,
            outputDirectory: output,
            jobID: output.lastPathComponent,
            chapterStart: 0,
            chapterEnd: 0,
            options: ConversionOptions(
                engine: AudioEnginePreference.piper.rawValue,
                language: "pt-BR",
                modelsRoot: root.path,
                modelID: "pt_BR-edresson-low",
                espeakDataDirectory: Bundle.main.resourceURL?.path
            )
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let manifest = try XCTUnwrap(payload["manifest"] as? [String: Any])
        let chapters = try XCTUnwrap(manifest["chapters"] as? [[String: Any]])
        let filename = try XCTUnwrap(chapters.first?["filename"] as? String)
        let audioURL = output.appendingPathComponent(output.lastPathComponent).appendingPathComponent(filename)
        XCTAssertGreaterThan(try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)

        let player = try AVAudioPlayer(contentsOf: audioURL)
        XCTAssertGreaterThan(player.duration, 0)
    }
    #endif

    func testOptionsEncodeExactRustKeysAndLiteralVoiceLanguage() throws {
        let options = ConversionOptions(engine: "piper", voice: "speaker-0", language: "pt-BR",
                                        clearCache: true, forceReprocess: true, maxPerformance: true)
        let json = try options.encodedJSON()
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["schema_version", "engine", "voice", "language", "clear_cache", "force_reprocess", "max_performance"]))
        XCTAssertEqual(fields["schema_version"] as? Int, 1)
        XCTAssertEqual(fields["voice"] as? String, "speaker-0")
        XCTAssertEqual(fields["language"] as? String, "pt-BR")
        XCTAssertEqual(fields["clear_cache"] as? Bool, true)
        XCTAssertEqual(fields["force_reprocess"] as? Bool, true)
        XCTAssertEqual(fields["max_performance"] as? Bool, true)
    }

    func testExplicitOptionsNeverFallBackToAnUnavailableABI() throws {
        let adapter = ConverterFFIAdapter(libraryURL: URL(fileURLWithPath: "/unused-converter-library.dylib"))
        XCTAssertThrowsError(try adapter.convertBook(at: URL(fileURLWithPath: "/must-not-open-book.epub"),
                                                   outputDirectory: URL(fileURLWithPath: "/must-not-create-output"),
                                                   jobID: "must-not-create-output", options: ConversionOptions(engine: "piper"))) {
            XCTAssertEqual($0 as? EmbeddedConverterError, .optionsABIUnavailable)
        }
    }

    func testActualSwiftRustOptionsRejectUnsupportedValuesBeforeOutputWork() throws {
        let adapter = try runtimeAdapter()
        let bookURL = try EpubFixture.createWithChapter()
        defer { try? FileManager.default.removeItem(at: bookURL) }
        _ = try adapter.openBook(at: bookURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ffi-options-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked-output")
        let original = Data("Original output fixture".utf8)
        try original.write(to: blocked)
        for (options, expected) in [
            (ConversionOptions(engine: "coqui"), "unsupported conversion engine"),
            (ConversionOptions(language: "\n"), "language"),
        ] {
            XCTAssertThrowsError(try adapter.convertBook(at: bookURL, outputDirectory: blocked, jobID: "blocked-output",
                                                       chapterStart: 0, chapterEnd: 0, options: options)) {
                XCTAssertTrue($0.localizedDescription.contains(expected), "Unexpected boundary error: \($0)")
            }
        }
        for options: ConversionOptions? in [
            nil,
            ConversionOptions(engine: "edge", voice: "pt-BR-FranciscaNeural", language: "pt-BR"),
            ConversionOptions(clearCache: true),
            ConversionOptions(forceReprocess: true),
            ConversionOptions(maxPerformance: true),
            ConversionOptions(clearCache: true, forceReprocess: true, maxPerformance: true),
        ] {
            XCTAssertThrowsError(try adapter.convertBook(at: bookURL, outputDirectory: blocked, jobID: "blocked-output",
                                                       chapterStart: 0, chapterEnd: 0, options: options)) {
                XCTAssertTrue($0.localizedDescription.contains("create output directory"), "Valid options did not reach the output boundary: \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: blocked), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["blocked-output"])
    }

    #if APP_FOUNDATION_HOST_TESTS
    func testOptInLiveEdgeStreamingProducesChapterAudioThroughSwiftFFI() async throws {
        guard ProcessInfo.processInfo.environment["APP_FOUNDATION_LIVE_EDGE"] == "1" else {
            throw XCTSkip("Set APP_FOUNDATION_LIVE_EDGE=1 to exercise the live Edge endpoint.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-edge-ffi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try EpubFixture.createWithChapter(
            body: "Teste breve de síntese Edge pelo FFI nativo do aplicativo.",
            includeCover: false
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let adapter = try runtimeAdapter()
        let manager = ObservedSupportManager(root: root)
        let coordinator = RustConversionCoordinator(adapter: adapter, fileManager: manager)
        let jobID = "live-edge-\(UUID().uuidString)"
        let chunks = FFIChunkCollector()
        let result = try await coordinator.convert(
            bookURL: source,
            jobID: jobID,
            chapterStart: 0,
            chapterEnd: 0,
            options: ConversionOptions(engine: "edge", voice: "pt-BR-FranciscaNeural", language: "pt-BR"),
            playbackControl: try adapter.makePlaybackControl(),
            onAudioChunk: { chapterIndex, chunkIndex, bytes in
                chunks.append(chapter: chapterIndex, index: chunkIndex, bytes: bytes)
                return true
            }
        )

        let manifest = try result.snapshot()
        let chapter = try XCTUnwrap(manifest.chapterProgress?.first)
        let audioURL = URL(fileURLWithPath: try XCTUnwrap(chapter.downloadUrl))
        XCTAssertEqual(chapter.index, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertGreaterThan(try Data(contentsOf: audioURL).count, 0)
        XCTAssertGreaterThan(chunks.snapshot().count, 0, "Rust FFI must deliver at least one Edge audio chunk.")
        print("LIVE_EDGE_FFI job=\(jobID) chunks=\(chunks.snapshot().count) audioBytes=\((try Data(contentsOf: audioURL)).count) path=\(audioURL.path)")
    }

    func testOptInLiveEdgeWholeBookConvertCreatesMP3AndArchive() async throws {
        guard ProcessInfo.processInfo.environment["APP_FOUNDATION_LIVE_EDGE"] == "1" else {
            throw XCTSkip("Set APP_FOUNDATION_LIVE_EDGE=1 to exercise the live Edge endpoint.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-edge-convert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try EpubFixture.createWithChapter(
            body: "Conversão integral Edge para validar o botão manual Converter.",
            includeCover: false
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let coordinator = RustConversionCoordinator(
            adapter: try runtimeAdapter(),
            fileManager: ObservedSupportManager(root: root)
        )
        let jobID = "live-edge-convert-\(UUID().uuidString)"
        let result = try await coordinator.convert(
            bookURL: source,
            jobID: jobID,
            options: ConversionOptions(
                engine: "edge", voice: "pt-BR-FranciscaNeural", language: "pt-BR",
                forceReprocess: true
            )
        )

        let snapshot = try result.snapshot()
        let chapter = try XCTUnwrap(snapshot.chapterProgress?.first)
        let audioURL = URL(fileURLWithPath: try XCTUnwrap(chapter.downloadUrl))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: result.manifestJSON) as? [String: Any])
        let manifest = try XCTUnwrap(envelope["manifest"] as? [String: Any])
        let archiveName = try XCTUnwrap(manifest["archive"] as? String)
        let archiveURL = result.outputDirectory.appendingPathComponent(archiveName)

        XCTAssertEqual(snapshot.chaptersTotal, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertGreaterThan(try Data(contentsOf: audioURL).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertGreaterThan(try Data(contentsOf: archiveURL).count, 0)
        print("LIVE_EDGE_CONVERT job=\(jobID) audioBytes=\((try Data(contentsOf: audioURL)).count) archiveBytes=\((try Data(contentsOf: archiveURL)).count)")
    }
    #endif
}

#if APP_FOUNDATION_HOST_TESTS
private final class FFIChunkCollector: @unchecked Sendable {
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

private final class FaberInferenceEvidence: @unchecked Sendable {
    struct FirstChunk { let chapter: Int; let index: Int; let bytes: Data; let time: Double }
    private let lock = NSLock()
    private var firstChunk: FirstChunk?
    private var received = 0
    func capture(chapter: Int, index: Int, bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        received += 1
        if firstChunk == nil { firstChunk = FirstChunk(chapter: chapter, index: index, bytes: bytes, time: ProcessInfo.processInfo.systemUptime) }
    }
    func first() -> FirstChunk? { lock.lock(); defer { lock.unlock() }; return firstChunk }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return received }
}
