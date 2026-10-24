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

extension ConversionOptionsInteropTests {
#if os(macOS) && !APP_FOUNDATION_HOST_TESTS
    @MainActor
    func testOptInMacConvertButtonUsesConfiguredEdgeAndProducesRealMP3() async throws {
        guard ProcessInfo.processInfo.environment["APP_FOUNDATION_LIVE_EDGE"] == "1" else {
            throw XCTSkip("Enable APP_FOUNDATION_LIVE_EDGE=1 for the visible macOS conversion journey.")
        }
        try await exerciseMacConvertButton(engine: .edge)
    }
#endif

#if os(macOS) && !APP_FOUNDATION_HOST_TESTS
    @MainActor
    func testOptInMacConvertButtonUsesInstalledSystemVoiceAndProducesRealMP3() async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_NATIVE_TTS_TEST"] == "1" else {
            throw XCTSkip("Enable EPUB2MP3_NATIVE_TTS_TEST=1 for the visible installed-voice conversion journey.")
        }
        try await exerciseMacConvertButton(engine: .system)
    }
#endif

    func testOptInSystemProviderPublishesPlayableMP3ThroughRust() async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_NATIVE_TTS_TEST"] == "1" else {
            throw XCTSkip("Enable EPUB2MP3_NATIVE_TTS_TEST=1 to exercise Apple PCM through Rust MP3 encoding.")
        }
        let source = try EpubFixture.createWithChapter(body: "Olá. Este pequeno capítulo testa a voz local.")
        defer { try? FileManager.default.removeItem(at: source) }
        let outputRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputRoot) }
        let outputStore = RustConversionOutputStore(root: outputRoot, notificationCenter: NotificationCenter())
        let result = try await RustConversionCoordinator(adapter: runtimeAdapter(), outputStore: outputStore).convert(
            bookURL: source, options: ConversionOptions(engine: "system", language: "pt-BR")
        )
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
        let outputRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputRoot) }
        let outputStore = RustConversionOutputStore(root: outputRoot, notificationCenter: NotificationCenter())
        let result = try await RustConversionCoordinator(adapter: runtimeAdapter(), outputStore: outputStore).convert(
            bookURL: source, options: ConversionOptions(
                engine: "edge", voice: "pt-BR-UnavailableFixtureVoice", language: "pt-BR"
            )
        )
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: result.manifestJSON) as? [String: Any])
        XCTAssertEqual(envelope["systemVoiceUsed"] as? Bool, true)
        let chapter = try XCTUnwrap(result.snapshot().chapterProgress?.first)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: try XCTUnwrap(chapter.downloadUrl)))
        XCTAssertGreaterThan(audio.length, 0)
    }

#if os(iOS) && targetEnvironment(simulator)
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
        _ = try adapter.installTtsModelFromCatalog(modelID: "pt_BR-faber-medium", root: root.path)
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
                modelID: "pt_BR-faber-medium",
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
        let coordinator = RustConversionCoordinator(adapter: adapter, fileManager: manager,
            outputStore: RustConversionOutputStore(root: root.appendingPathComponent("outputs"), notificationCenter: NotificationCenter()))
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
#endif

#if APP_FOUNDATION_HOST_TESTS
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
            fileManager: ObservedSupportManager(root: root),
            outputStore: RustConversionOutputStore(root: root.appendingPathComponent("outputs"), notificationCenter: NotificationCenter())
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
