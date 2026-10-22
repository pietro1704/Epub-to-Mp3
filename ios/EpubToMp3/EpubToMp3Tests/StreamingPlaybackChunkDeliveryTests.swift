#if os(macOS) || os(iOS)
import XCTest
import AVFoundation
@testable import EpubToMp3

@MainActor
final class StreamingPlaybackChunkDeliveryTests: XCTestCase {
    func testOptInLiveEdgeChunkPlaysBeforeFFIConversionReturns() async throws {
        try await verifyLiveChunkPlayback(engine: "edge")
    }

    func testOptInSystemChunkPlaysBeforeFFIConversionReturns() async throws {
        try await verifyLiveChunkPlayback(engine: "system")
    }

    private func verifyLiveChunkPlayback(engine: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        let libraryPath = environment["APP_FOUNDATION_FFI_LIBRARY"]
        if engine == "system" {
            guard environment["EPUB2MP3_NATIVE_TTS_TEST"] == "1" else {
                throw XCTSkip("Enable EPUB2MP3_NATIVE_TTS_TEST=1 for real system-voice playback.")
            }
        } else {
            guard environment["APP_FOUNDATION_LIVE_EDGE"] == "1", let libraryPath, !libraryPath.isEmpty else {
                throw XCTSkip("Set APP_FOUNDATION_LIVE_EDGE=1 and APP_FOUNDATION_FFI_LIBRARY to run live Edge playback.")
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-edge-player-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try EpubFixture.createWithChapter(
            body: String(repeating: "Teste breve de áudio sendo reproduzido pelo player nativo. ", count: 8),
            includeCover: false
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let adapter = libraryPath.flatMap { $0.contains("$(") || $0.isEmpty ? nil : $0 }
            .map { ConverterFFIAdapter(libraryURL: URL(fileURLWithPath: $0)) } ?? ConverterFFIAdapter()
        let coordinator = RustConversionCoordinator(
            adapter: adapter,
            fileManager: NativeFFITestFileManager(root: root)
        )
        let player = AudioPlayer()
        let jobID = "live-edge-player-\(UUID().uuidString)"
        let pending = JobSnapshot(
            jobId: jobID, state: "running", bookTitle: "Live Edge fixture", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: "edge", voice: nil, language: "pt-BR",
            progressPercent: 0, chaptersTotal: nil, chaptersCompleted: 0, chapterProgress: [],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: Date().timeIntervalSince1970
        )
        player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
        player.isConverting = true
        player.resume()
        defer { player.stop() }

        let delivery = StreamingPlaybackChunkDelivery(player: player)
        let firstChunkAccepted = expectation(description: "The real Edge MP3 chunk reaches AudioPlayer")
        let releaseRustCallback = DispatchSemaphore(value: 0)
        let conversionReturned = NativeFFIBool()
        let usedSystemVoice = NativeFFIBool()
        let chunks = NativeFFIChunkCount()
        defer { releaseRustCallback.signal() }

        let conversion = Task {
            defer { conversionReturned.set(true) }
            return try await coordinator.convert(
                bookURL: source,
                jobID: jobID,
                chapterStart: 0,
                chapterEnd: 0,
                options: ConversionOptions(engine: engine, voice: engine == "edge" ? "pt-BR-FranciscaNeural" : nil, language: "pt-BR"),
                playbackControl: try adapter.makePlaybackControl(),
                onProgress: { event in if event.engine == "system" { usedSystemVoice.set(true) } },
                onAudioChunk: { chapterIndex, chunkIndex, bytes in
                    chunks.increment()
                    let accepted = delivery.enqueue(
                        bytes,
                        chapterIndex: chapterIndex,
                        chunkIndex: chunkIndex,
                        isCurrent: { true },
                        onAccepted: {}
                    )
                    if accepted && chapterIndex == 0 && chunkIndex == 0 {
                        firstChunkAccepted.fulfill()
                        _ = releaseRustCallback.wait(timeout: .now() + 10)
                    }
                    return accepted
                }
            )
        }

        await fulfillment(of: [firstChunkAccepted], timeout: 15)
        XCTAssertTrue(player.firstSegmentReady)
        if engine == "edge" { XCTAssertFalse(usedSystemVoice.get()); XCTAssertFalse(player.isUsingSpeechFallback) }
        XCTAssertTrue(player.isPlaying)
        let item = try XCTUnwrap(player.testHook_currentPlayerItem())
        for _ in 0..<30 where item.status == .unknown {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(item.status, .readyToPlay, "status=\(item.status.rawValue), error=\(String(describing: item.error))")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(item.currentTime().seconds, 0.02, "status=\(item.status.rawValue), error=\(String(describing: item.error))")
        XCTAssertFalse(conversionReturned.get(), "Playback must begin while Rust conversion is still held at the accepted first chunk.")
        XCTAssertEqual(chunks.get(), 1, "The chapter must still await its later audio chunks when playback starts.")

        releaseRustCallback.signal()
        let result = try await conversion.value
        let manifest = try result.snapshot()
        let chapter = try XCTUnwrap(manifest.chapterProgress?.first)
        let audioURL = URL(fileURLWithPath: try XCTUnwrap(chapter.downloadUrl))
        XCTAssertGreaterThan(try Data(contentsOf: audioURL).count, 0)
        XCTAssertTrue(conversionReturned.get())
        if engine == "edge" { XCTAssertFalse(usedSystemVoice.get()); XCTAssertFalse(player.isUsingSpeechFallback) }
        XCTAssertGreaterThanOrEqual(chunks.get(), 2, "The first playable chunk must represent only part of this chapter.")
    }

    func testWorkerChunkEntersPlayerAndHonorsExplicitListenIntent() async throws {
        let player = AudioPlayer()
        let jobID = UUID().uuidString
        let pending = JobSnapshot(
            jobId: jobID, state: "running", bookTitle: "Streaming fixture", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: "edge", voice: nil, language: nil,
            progressPercent: 0, chaptersTotal: nil, chaptersCompleted: 0, chapterProgress: [],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: Date().timeIntervalSince1970
        )
        player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
        player.isConverting = true
        player.resume()
        let delivery = StreamingPlaybackChunkDelivery(player: player)
        // Valid mono MP3 from a short 440 Hz fixture; AVQueuePlayer must decode it.
        let bytes = Data(base64Encoded: """
        //NIxAAceI5sFVgwACVa9U6p1TqnVOqdd7E2vrCImFyE6GjgE5tic4m0poEYAFmC8CgjEHIhyWEy
        YDAYDCyaYOAgCAIOicH+UdOdPnOX85y/u6fdlATB8+sPggGJQBg++TBA5l393Lg+D4Ph8EAQBAEA
        GD4Pg+HwQBAEHJE4PiAJIIEAaBBgWB2+f5gyFQEB//NIxBEgofZsLZ2gAJ0MgD6DpiMT5rslRg0V
        RsQephGLxwyMIGLggaAeBhhYGKYgoLJwDJYgGgxdDZgtGC0IUj/iURBUcoXMLm/8mRzRzSaIsRb/
        8mSKkBMiLEWMf/8ul0yLxeRLpdS///LxeRLpdBoKgqz/5YKhot////VaqqAAAJIIoQ/n//QM6Uyg
        tvDA//NIxBEZmHYmN95AADwFDAlBkMIEBYwggzTFuO9OXQwY/ZT/DK7LiMdYWsxNCRzADD9MHICM
        wDgAU7lYoegELKGttzM5u/Yv9b/+8ndXr/3l7+TW7s+5u39lxD7qj+7u/T1V///UqUFMJBjIBszR
        HM3bjQqswGUEcMC8CLTB0xlQynT+uNZLISjBhAeEwNUB//NIxC0j47oEAN/EcMDCjA0cwQ8E3MDv
        ASDAUABUwB8AADAA1M5vJJKabf611aGaFw+PQXv/XPQJvU1Hq1R6tfTfT49Xq1cmTFJ0bf1aFybY
        3rq1fg9dqkoNB6PZ4LJunvRtq/67Y/rr8NOoxW929YAAEfv/5K1hC6Y8ACigAuYAYAiGAdgP5gOQ
        G4YGuDYm//NIxCAhA74N6P9EqA7QmUZLXeNGnxDNhhPoRqasrCcHYUZpn0ZSheYXAMEA2gMV2xB/
        I3hf/3rrq1MmSor/+Wh9sbfbHrrrt/V6vXXNrjen+uTPvn2q1dXrk+famumCz59vvRqt/6ev11+D
        lrU6dhWgAAwGZ/Lv9oWMFgAwuAACB4aFUMJ8yGAgz5CE40E4//NIxB8fg74V9O/KiMuzBfDYyAKo
        wosDxMC5BQTARg74wAkFMFAEsdAFCAABY09cMAgaO71113z647010xlG3z/bev++/rq9frkz/f/z
        NHZM21WjdH9/p6PXTdrZM/9GjdP9fjvX/EJW/enqgAR+Pf+q7SEkwYAx5QySkz8QwDYB9MBvBAjB
        GgxExm193M28//NIxCQY4HYZSNf4ZhAMwQUDGMhFk5f/jOiyM0B8wyAAwAq6dWjr1g1tvZuqO/vT
        cm5Cnp6PcT6tWnqtTo0Lszu5N7dqr/2/7vz+7pX//+UjX0uEDhCBwJDMwaGAxDK0yEVQ0v9kxg6Y
        tMzRFJzBrAawDfjuA8/8QNSJUDPwQAOIYFgQG/ilBmyLlxP69T1a//NIxEMaGN4UAO/qgLfbP/2i
        WfRdU9m1PuJ306/84Vs3oXZs31vatwbXd6rf9/7kfT0KgAAJFCf5//cetbC8S/I8IwMVDKYTNPDQ
        7qpTH1BjM0KMEBMG0AtjII1DFOfTBA1QoExCAajj1xCV27z+rXcmz9haz1PZ/uJq15bR88r/7ehd
        q7EX+qlfv3/nk/T1//NIxF0XSHYh9Of6gFWgAACRQEVn9//64CciwpckwDwFTAtA3CgPxhoCVGQ8
        d8aaXYhzcjEmLaGqYMYXpg8i3mBqECYQIIZgMgFpZLEa5FBBDNdi9OjT02/s/9dmz/127vXq+SXb
        nkfZf//rIGFKKKJAA/0sDAMEzBIMTCYD/LMhAPqlAIhGEQvmG5CHYJDm//NIxIIXgHouPV4wAC2m
        po6tBkoaZoMlZiTEHA1KGxRoRQBjAxEqEiYAC///u8XUT4jhhpALDQEFQSDf//6wjaRBrECMeQEq
        3PepT////DDOIEhhyIouaB05XCl65f////hh/JyMRixGH2lbKY1NuDKv/////4xYjEs5GKTksoXZ
        ppl/cpmGcv///////6Tl//NIxKc1qnJkVZ3YACWOUlj6TD6SrS/Vpfq0v1bO/6CjjhScKAqJQmCo
        lGhpv/lJxFyMqNDQlGnRKsJAqkQjKgzgY8higBVkNeD/4MSFzG1xtMXSfctyZEmgrFkMS4req3Ir
        NnQEmAI6hXQVI/Yiejk9E1VR+lxUNH106aLkwqFlpbLChsZ6yxfbL1W7gva+//NIxFMcMUYMAdh4
        ANmC93Wtf/V6BQ1KhsSugqs7Wd///////////T7+WkxBTUU0LjCqqqqqqqqqqqqqqqqqqqqqqqqq
        qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        qqqqqqqqqqqqqqqqqqqqqqqqq
        """, options: .ignoreUnknownCharacters)!
        defer { player.stop() }

        let accepted = await Task.detached {
            delivery.enqueue(
                bytes,
                chapterIndex: 0,
                chunkIndex: 0,
                isCurrent: { true },
                onAccepted: {}
            )
        }.value

        XCTAssertTrue(accepted, "A current Rust worker chunk must be accepted by the player bridge.")
        XCTAssertTrue(player.firstSegmentReady)
        XCTAssertTrue(player.isPlaying, "Listen intent must start audio when the first chunk arrives.")
        let item = try XCTUnwrap(player.testHook_currentPlayerItem())
        for _ in 0..<30 where item.status == .unknown {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertGreaterThan(
            item.currentTime().seconds,
            0.02,
            "A valid encoded audio segment must advance playback."
        )
    }
}

private final class NativeFFITestFileManager: FileManager, @unchecked Sendable {
    private let root: URL
    init(root: URL) { self.root = root; super.init() }

    override func url(for directory: SearchPathDirectory, in domain: SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        root
    }
}

private final class NativeFFIBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
private final class NativeFFIChunkCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
