import Foundation
import XCTest
import AVFoundation
import CryptoKit
#if os(iOS)
import UIKit
#endif
@testable import EpubToMp3

/// Requires the real app bundle and its installed offline speech resources.
final class FaberNativeInferenceTests: XCTestCase {
    @MainActor
    func testOptInFaberStreamsFirstPlayableAudioAndPublishesOfflineChapters() async throws {
        guard let suppliedRoot = ProcessInfo.processInfo.environment["EPUB2MP3_PIPER_TEST_MODEL_ROOT"],
              !suppliedRoot.isEmpty, !suppliedRoot.contains("$("), !suppliedRoot.contains("${") else {
            throw XCTSkip("Set EPUB2MP3_PIPER_TEST_MODEL_ROOT to the existing original Faber model directory; this test never downloads voices.")
        }
        let fixtureRoot = try modelFixtureRoot(suppliedRoot)
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
        let metadata: [String: Any] = [
            "id": "pt_BR-faber-medium", "revision": artifacts.map(\.hash).joined(separator: ":"),
            "artifacts": artifacts.map { ["path": $0.target, "sha256": $0.hash] },
        ]
        try JSONSerialization.data(withJSONObject: metadata).write(to: modelDirectory.appendingPathComponent("metadata.json"))
        let adapter = ConverterFFIAdapter()
        let current = SpeechModelLibraryTarget.current()
        let modelTarget = SpeechModelLibraryTarget(
            language: "pt-BR", platform: current.platform, androidAPI: current.androidAPI,
            architecture: current.architecture, osVersion: current.osVersion, modelsRoot: models
        )
        let installed = try adapter.speechModelSnapshot(target: modelTarget)
        XCTAssertEqual(installed.entries.first { $0.identity.modelID == "pt_BR-faber-medium" }?
            .installation.state, .installed)
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("espeak-ng-data/phontab").path),
                      "The real application must bundle eSpeak data before offline synthesis.")
        let book = try EpubFixture.createWithChapters([
            "Olá. Esta primeira página verifica a voz Faber em português. O áudio começa antes de terminar a conversão completa.",
            "Neste segundo capítulo, a mesma voz continua funcionando sem internet. Cada palavra deve produzir áudio válido e audível.",
        ])
        defer { try? FileManager.default.removeItem(at: book) }
        let control = try adapter.makePlaybackControl()
        control.updatePlaybackWindow(currentChapter: 0, chaptersAhead: 1)
        var options = ConversionOptions.selectedEngine(.piper, modelsRoot: models)
        options.language = "pt-BR"
        options.espeakDataDirectory = resources.path
        options.ttsPreferences = TtsPreferences(primary: .selected(.piper), secondary: nil, allowOnlineFallback: false)
        let chunks = FaberInferenceEvidence()
        var providers: [RustConversionCoordinator.ConversionProgressEvent] = []
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await RustConversionCoordinator(
            adapter: adapter,
            outputStore: RustConversionOutputStore(root: root.appendingPathComponent("outputs", isDirectory: true))
        ).convert(
            bookURL: book, chapterStart: 0, chapterEnd: 1, options: options, playbackControl: control,
            onProgress: { event in if event.modelId != nil { providers.append(event) } },
            onAudioChunk: { chapter, index, bytes in chunks.capture(chapter: chapter, index: index, bytes: bytes); return true }
        )
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        XCTAssertTrue(
            result.outputDirectory.resolvingSymlinksInPath().standardizedFileURL.path
                .hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/"),
            "Offline inference must keep all job artifacts inside its owned temporary root."
        )
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
        try await verifyGeneratedAudioPlayback(snapshot: snapshot, root: root)
        print("FABER_NATIVE firstChunkSeconds=\(first.time - started) totalSeconds=\(elapsed) chunks=\(chunks.count()) firstPeak=\(firstPeak) engine=\(snapshot.engine ?? "") model=\(snapshot.voice ?? "") chapters=\(chapters.count)")
    }

    @MainActor
    private func verifyGeneratedAudioPlayback(snapshot: JobSnapshot, root: URL) async throws {
        let suiteName = "faber-playback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
                          "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
                          "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
                          "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"]
        let savedWidget = widgetKeys.map { widget?.object(forKey: $0) }
        for key in keys { standard.removeObject(forKey: key) }
        widget?.set("", forKey: "currentlyPlayingBookId")
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer {
            player.stop()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            for (key, value) in zip(widgetKeys, savedWidget) { widget?.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suiteName)
        }
        player.play(snapshot: snapshot, startingAt: 0, restoreAutoplay: false)
        XCTAssertFalse(player.isPlaying)

        #if os(iOS)
        let controller = FullPlayerScreenController(
            player: player, playbackClock: player.playbackClock,
            library: LibraryStore(defaults: defaults, importDirectory: root),
            playerPresentation: PlayerPresentation(defaults: defaults), settings: AppSettings(defaults: defaults),
            onStartListening: {}
        )
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive },
            "Visible playback evidence requires the app's active foreground scene."
        )
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await waitForPlayback {
            window.isKeyWindow && !window.isHidden && scene.activationState == .foregroundActive
                && window.bounds.width > 0 && window.bounds.height > 0
        }
        #endif

        player.resume()
        try await waitForPlayback { player.isPlaying && player.positionSeconds > 0.1 }
        XCTAssertEqual(player.snapshot?.jobId, snapshot.jobId)
        XCTAssertFalse(player.isUsingSpeechFallback, "Generated Faber MP3s must use the real audio transport.")
        #if os(iOS)
        guard window.isKeyWindow, !window.isHidden, scene.activationState == .foregroundActive,
              controller.view.window === window else {
            XCTFail("Playback screenshot requires the visible key window in the active foreground scene.")
            throw NSError(domain: "FaberNativeInferenceTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "The playback evidence window is not visible and active."])
        }
        let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        screenshot.name = "faber-generated-audio-real-player"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #endif
        player.pause()
        XCTAssertFalse(player.isPlaying)
        let paused = player.positionSeconds
        try await Task.sleep(nanoseconds: 400_000_000)
        let pauseStable = abs(player.positionSeconds - paused) <= 0.2
        XCTAssertEqual(player.positionSeconds, paused, accuracy: 0.2)

        #if os(iOS)
        try tapPlayerButton("fullPlayer.nextChapter", in: controller.view)
        #else
        player.nextChapter()
        #endif
        try await waitForPlayback { player.currentChapterIndex == 1 && !player.isSeeking }
        let nextPreservedPause = !player.isPlaying
        XCTAssertFalse(player.isPlaying, "Next generated chapter must preserve explicit pause.")
        #if os(iOS)
        try tapPlayerButton("fullPlayer.previousChapter", in: controller.view)
        #else
        player.previousChapter()
        #endif
        try await waitForPlayback { player.currentChapterIndex == 0 && !player.isSeeking }
        let previousPreservedPause = !player.isPlaying
        XCTAssertFalse(player.isPlaying, "Previous generated chapter must preserve explicit pause.")
        let beforeResume = player.positionSeconds
        player.resume()
        try await waitForPlayback { player.isPlaying && player.positionSeconds > beforeResume + 0.1 }
        player.pause()
        let evidence = XCTAttachment(string: "jobID=\(snapshot.jobId); engine=\(snapshot.engine ?? ""); model=\(snapshot.voice ?? ""); pausedPosition=\(paused); resumedPosition=\(player.positionSeconds); chapters=\(snapshot.playableChapters.count); playing=\(player.isPlaying)")
        evidence.name = "faber-generated-audio-transport-evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
        print("FABER_PLAYER_TRANSPORT job=\(snapshot.jobId) clockAdvanced=true pauseStable=\(pauseStable) nextPreservedPause=\(nextPreservedPause) previousPreservedPause=\(previousPreservedPause)")
    }

    @MainActor
    private func waitForPlayback(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(predicate(), "Generated-audio transport must settle within 15 seconds.")
        if !predicate() {
            throw NSError(domain: "FaberNativeInferenceTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Generated-audio playback did not settle."])
        }
    }

    #if os(iOS)
    @MainActor
    private func tapPlayerButton(_ identifier: String, in view: UIView) throws {
        func find(_ view: UIView) -> UIButton? {
            if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
            return view.subviews.compactMap(find).first
        }
        let button = try XCTUnwrap(find(view), "The visible player must expose \(identifier).")
        XCTAssertTrue(button.isEnabled)
        button.sendActions(for: .touchUpInside)
    }
    #endif

    func testDeviceTemporaryModelFixtureStaysInsideItsOwnedNamespace() throws {
        let root = try modelFixtureRoot("app-temporary:faber-fixture/models")
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(root.path, temporary.appendingPathComponent("faber-fixture/models", isDirectory: true).path)
        for invalid in ["app-temporary:", "app-temporary:/outside", "app-temporary:../outside",
                        "app-temporary:owned/../outside", "app-temporary:owned//models",
                        "app-temporary:owned\\models", "relative/models"] {
            XCTAssertThrowsError(try modelFixtureRoot(invalid), "Accepted unsafe model fixture: \(invalid)")
        }
    }

    private func modelFixtureRoot(_ suppliedRoot: String) throws -> URL {
        let prefix = "app-temporary:"
        if suppliedRoot.hasPrefix(prefix) {
            let relative = String(suppliedRoot.dropFirst(prefix.count))
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            let candidate = temporary.appendingPathComponent(relative, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            guard !relative.contains("\\"), !relative.contains("\0"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  candidate.path.hasPrefix(temporary.path + "/") else {
                throw NSError(domain: "FaberNativeInferenceTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The device model fixture must remain inside its app-temporary namespace."])
            }
            return candidate
        }
        guard suppliedRoot.hasPrefix("/") else {
            throw NSError(domain: "FaberNativeInferenceTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Use an absolute host path or app-temporary:<owned-directory>/models."])
        }
        return URL(fileURLWithPath: suppliedRoot, isDirectory: true)
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

}

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
