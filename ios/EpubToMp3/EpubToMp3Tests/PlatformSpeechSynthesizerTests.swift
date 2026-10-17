import AVFoundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class PlatformSpeechSynthesizerTests: XCTestCase {
    func testFallbackNoticeOccursOncePerJobAndNeverForEdge() {
        let edge = Data("{\"engine\":\"edge\"}".utf8)
        let system = Data("{\"engine\":\"system\"}".utf8)
        let firstJob = PlatformFallbackNoticeTracker()
        XCTAssertFalse(firstJob.shouldNotify(progress: edge))
        XCTAssertFalse(firstJob.shouldNotify(progress: Data("invalid".utf8)))
        XCTAssertTrue(firstJob.shouldNotify(progress: system))
        XCTAssertFalse(firstJob.shouldNotify(progress: system))
        XCTAssertTrue(PlatformFallbackNoticeTracker().shouldNotify(progress: system))
    }

    func testConfiguredSecondaryNoticeIsOncePerJob() {
        let tracker = PlatformFallbackNoticeTracker()
        let primary = Data(#"{"engine":"piper","fallbackUsed":false}"#.utf8)
        let secondary = Data(#"{"engine":"edge","fallbackUsed":true}"#.utf8)
        XCTAssertFalse(tracker.shouldNotify(progress: primary))
        XCTAssertTrue(tracker.shouldNotify(progress: secondary))
        XCTAssertFalse(tracker.shouldNotify(progress: secondary))
    }

    func testFaberIsAvailableAsAnExplicitOfflineProvider() {
        XCTAssertEqual(AudioEnginePreference.supportedPreferences, [.piper, .system, .edge])
        XCTAssertEqual(ConversionOptions.selectedEngine(.piper).engine, "piper")
        XCTAssertEqual(ConversionOptions.selectedEngine(.piper).modelID, "pt_BR-faber-medium")
    }

    func testLucianaIsPreferredEvenWhenOnlyEnhancedVersionIsInstalled() {
        let voices: [InstalledSpeechVoicePolicy.Voice] = [
            .init(identifier: "compact.other", name: "Other", language: "pt-BR", isCompact: true),
            .init(identifier: "enhanced.luciana", name: "Luciana", language: "pt-BR", isCompact: false),
            .init(identifier: "portugal", name: "Luciana", language: "pt-PT", isCompact: true),
        ]
        XCTAssertEqual(InstalledSpeechVoicePolicy.select(language: "pt_BR", voices: voices), "enhanced.luciana")
        XCTAssertEqual(InstalledSpeechVoicePolicy.select(language: "pt", voices: voices), "enhanced.luciana")
        XCTAssertEqual(InstalledSpeechVoicePolicy.select(language: "pt-PT", voices: voices), "portugal")
        XCTAssertNil(InstalledSpeechVoicePolicy.select(language: "es-ES", voices: voices))
    }

    func testInstalledVoiceFallbackIsDeterministicAndNeverCrossesExplicitRegion() {
        let voices: [InstalledSpeechVoicePolicy.Voice] = [
            .init(identifier: "z.voice", name: "Other", language: "pt-BR", isCompact: true),
            .init(identifier: "a.voice", name: "Another", language: "pt-BR", isCompact: true),
            .init(identifier: "first", name: "Portugal", language: "pt-PT", isCompact: true),
        ]
        XCTAssertEqual(InstalledSpeechVoicePolicy.select(language: "pt", voices: voices), "a.voice")
        XCTAssertEqual(InstalledSpeechVoicePolicy.select(language: "PT-br", voices: Array(voices.reversed())), "a.voice")
        XCTAssertNil(InstalledSpeechVoicePolicy.select(language: "pt-BR", voices: [voices[2]]))
        XCTAssertNil(InstalledSpeechVoicePolicy.select(language: "pt-BR", voices: []))
    }

    func testLegacyPreferenceSnapshotRetainsAbsentPolicyAndExplicitNoFallback() throws {
        let data = Data(#"{"primary":{"engine":"piper","model_id":"pt_BR-faber-medium"},"secondary":null,"allow_online_fallback":false}"#.utf8)
        let preferences = try JSONDecoder().decode(TtsPreferences.self, from: data)
        XCTAssertNil(preferences.secondary)
        XCTAssertNil(preferences.policyVersion)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        XCTAssertNil(object["policy_version"])
    }

    func testNativeFallbackPolicyRoundTripsWithoutChangingPrimaryIdentity() throws {
        let preferences = TtsPreferences(primary: .selected(.piper), secondary: .selected(.system),
                                         allowOnlineFallback: false, policyVersion: 2)
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(TtsPreferences.self, from: data), preferences)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["policy_version"] as? Int, 2)
        XCTAssertEqual(ConversionOptions.selectedEngine(.system).engine, "system")
        XCTAssertNil(ConversionOptions.selectedEngine(.system).modelID)
        XCTAssertEqual(preferences.primary.modelID, "pt_BR-faber-medium")
        XCTAssertFalse(preferences.allowOnlineFallback)
    }

    @MainActor
    func testSystemSpeechRejectsMainThreadBeforeBlocking() {
        XCTAssertThrowsError(try PlatformSpeechSynthesizer().synthesizeWAV(
            text: "Hello", language: "en-US", output: URL(fileURLWithPath: "/unused.wav"), cancelled: { false }
        ))
    }

    func testPreCancelledRequestCreatesNoArtifact() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let failed = await Task.detached {
            do {
                try PlatformSpeechSynthesizer().synthesizeWAV(text: "Hello", language: "en-US",
                                                            output: url, cancelled: { true })
                return false
            } catch { return error.localizedDescription.contains("cancelled") }
        }.value
        XCTAssertTrue(failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnavailableLocaleDoesNotUseAnUnrelatedVoice() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let failed = await Task.detached {
            do {
                try PlatformSpeechSynthesizer().synthesizeWAV(text: "Hello", language: "zz-ZZ",
                                                            output: url, cancelled: { false }, timeout: 5)
                return false
            } catch { return error.localizedDescription.contains("No installed system voice") }
        }.value
        XCTAssertTrue(failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testQueuedRequestCanCancelBeforeActiveRequestReleasesProvider() async throws {
        let activeRequest = HeldSpeechRequest()
        defer { activeRequest.release() }
        let provider = PlatformSpeechSynthesizer(requestLock: activeRequest.lock)
        let queued = expectation(description: "The request observes cancellation while another request owns speech")
        let cancellation = SpeechCancellationProbe()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let task = Task.detached {
            do {
                try provider.synthesizeWAV(text: "Hello", language: "en-US", output: url,
                                           cancelled: { cancellation.check { queued.fulfill() } }, timeout: 2)
                return false
            } catch { return error.localizedDescription.contains("cancelled while queued") }
        }
        await fulfillment(of: [queued], timeout: 2)
        cancellation.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled, "Cancellation must finish while the active request still owns the speech lock.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTimeoutProducesNoArtifactAndNextRequestCanStart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let result = await Task.detached {
            let provider = PlatformSpeechSynthesizer()
            do {
                try provider.synthesizeWAV(text: "Hello", language: "en-US", output: url,
                                           cancelled: { false }, timeout: -1)
                return false
            } catch {
                guard error.localizedDescription.contains("timed out") else { return false }
            }
            do {
                try provider.synthesizeWAV(text: "Hello", language: "zz-ZZ", output: url,
                                           cancelled: { false }, timeout: 5)
                return false
            } catch { return error.localizedDescription.contains("No installed system voice") }
        }.value
        XCTAssertTrue(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOptInCancellationDuringSystemSpeechCreatesNoArtifact() async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_NATIVE_TTS_TEST"] == "1" else {
            throw XCTSkip("Enable EPUB2MP3_NATIVE_TTS_TEST=1 for real synthesis cancellation.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let result = await Task.detached {
            let deadline = Date().addingTimeInterval(0.2)
            do {
                try PlatformSpeechSynthesizer().synthesizeWAV(
                    text: String(repeating: "Olá, este texto continua por bastante tempo. ", count: 500),
                    language: "pt-BR", output: url, cancelled: { Date() >= deadline }
                )
                return false
            } catch { return error.localizedDescription.contains("cancelled") }
        }.value
        XCTAssertTrue(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOptInRealSystemSpeechProducesMonoPCM16WAV() async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_NATIVE_TTS_TEST"] == "1" else {
            throw XCTSkip("Enable EPUB2MP3_NATIVE_TTS_TEST=1 for actual installed Apple speech synthesis.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Task.detached {
            try PlatformSpeechSynthesizer().synthesizeWAV(
                text: "Olá. Esta é uma voz local gratuita.", language: "pt-BR", output: url, cancelled: { false }
            )
        }.value
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(data[34], 16)
        XCTAssertEqual(data[35], 0)
    }
}

private final class SpeechCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var checked = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    func check(firstCheck: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !checked { checked = true; firstCheck() }
        return cancelled
    }
}

private final class HeldSpeechRequest {
    let lock = NSLock()
    init() { lock.lock() }
    func release() { lock.unlock() }
}
