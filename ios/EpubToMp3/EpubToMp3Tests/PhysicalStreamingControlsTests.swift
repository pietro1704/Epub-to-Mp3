#if os(iOS)
import XCTest
import UIKit
import AVFoundation
@testable import EpubToMp3

@MainActor
final class PhysicalStreamingControlsTests: XCTestCase {
    func testOptInRealEdgeTwoChapterTransportControls() async throws {
        guard ProcessInfo.processInfo.environment["APP_IOS_LIVE_EDGE"] == "1" else {
            throw XCTSkip("Enable APP_IOS_LIVE_EDGE=1 for live Edge transport verification.")
        }
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
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
        widget?.set("", forKey: "currentlyPlayingBookId")
        standard.removeObject(forKey: AudioPlayer.currentBookIDDefaultsKey)
        defer {
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            for (key, value) in zip(widgetKeys, savedWidget) { widget?.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
        }
        let bodies = [
            String(repeating: "Primeiro capítulo. O áudio começa antes de terminar a conversão. ", count: 10),
            String(repeating: "Segundo capítulo. Os controles continuam respondendo durante a leitura. ", count: 10)
        ]
        let source = try EpubFixture.createWithChapters(bodies)
        defer { try? FileManager.default.removeItem(at: source) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let pending = JobSnapshot(
            jobId: identifier, state: "running", bookTitle: "Physical streaming controls", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: "edge", voice: "pt-BR-FranciscaNeural", language: "pt-BR",
            progressPercent: 0, chaptersTotal: 2, chaptersCompleted: 0,
            chapterProgress: bodies.enumerated().map { index, text in
                .init(index: index, name: "Chapter \(index + 1)", status: "pending", downloadUrl: nil,
                      chars: text.count, charsProcessed: 0, progressRatio: 0, durationSeconds: nil,
                      startedAt: nil, completedAt: nil)
            }, outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
        player.isConverting = true
        player.resume()
        let mini = MiniPlayerBarUIKitView()
        mini.frame = CGRect(x: 0, y: 0, width: 390, height: 104)
        mini.configure(player: player, playbackClock: PlaybackClock(),
                       library: LibraryStore(defaults: defaults, importDirectory: root), onTap: {})
        mini.layoutIfNeeded()
        let delivery = StreamingPlaybackChunkDelivery(player: player)
        let adapter = ConverterFFIAdapter()
        let coordinator = RustConversionCoordinator(adapter: adapter, fileManager: ControlsFileManager(root: root))
        let control = try adapter.makePlaybackControl()
        defer { control.cancel() }
        var usedSystem = false
        var completedChapters: [JobSnapshot.Chapter] = []
        let conversion = Task {
            try await coordinator.convert(
                bookURL: source, jobID: identifier, chapterStart: 0, chapterEnd: 1,
                options: ConversionOptions(engine: "edge", voice: "pt-BR-FranciscaNeural", language: "pt-BR"),
                playbackControl: control,
                onProgress: { event in if event.engine == "system" { usedSystem = true } },
                onChapterCompleted: { event in
                    completedChapters.removeAll { $0.index == event.chapterIndex }
                    completedChapters.append(event.playableChapter)
                    let chapters = (pending.chapterProgress ?? []).map { chapter in
                        completedChapters.first { $0.index == chapter.index } ?? chapter
                    }
                    player.updateSnapshot(event.snapshot(chapters: chapters))
                },
                onAudioChunk: { chapter, chunk, bytes in
                    delivery.enqueue(bytes, chapterIndex: chapter, chunkIndex: chunk,
                                     isCurrent: { true }, onAccepted: {})
                })
        }
        var watchdogExpired = false
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 90_000_000_000) }
            catch { return }
            watchdogExpired = true
            control.cancel()
            player.stop()
        }
        defer {
            watchdog.cancel()
            control.cancel()
            player.stop()
            conversion.cancel()
        }
        do {
            let started = ProcessInfo.processInfo.systemUptime
            try await waitUntil(timeout: 15) { player.firstSegmentReady && player.positionSeconds > 0.05 }
            print("PHYSICAL_CONTROLS first_audible_seconds=\(ProcessInfo.processInfo.systemUptime - started)")
            XCTAssertFalse(usedSystem, "The real Edge golden path must not use platform speech.")
            try tap("miniPlayer.playPause", in: mini)
            XCTAssertFalse(player.isPlaying)
            let paused = player.positionSeconds
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(player.positionSeconds, paused, accuracy: 0.2)
            try tap("miniPlayer.next", in: mini)
            try await waitUntil(timeout: 30) { player.currentChapterIndex == 1 && !player.isSeeking }
            XCTAssertFalse(player.isPlaying, "Next chapter must preserve explicit pause.")
            try tap("miniPlayer.previous", in: mini)
            try await waitUntil(timeout: 10) { player.currentChapterIndex == 0 && !player.isSeeking }
            XCTAssertFalse(player.isPlaying)
            try tap("miniPlayer.playPause", in: mini)
            let resumed = player.positionSeconds
            try await waitUntil(timeout: 5) { player.isPlaying && player.positionSeconds > resumed + 0.1 }
            player.setRate(.x150)
            let queue = Mirror(reflecting: player).children
                .first { $0.label == "player" }?.value as? AVQueuePlayer
            XCTAssertEqual(try XCTUnwrap(queue).rate, 1.5, accuracy: 0.01,
                           "Speed selection must change the actual generated-audio transport.")
            player.setRate(.x100)
            try tap("miniPlayer.next", in: mini)
            try await waitUntil(timeout: 10) { player.currentChapterIndex == 1 && !player.isSeeking && player.isPlaying }
            let result = try await conversion.value
            XCTAssertFalse(watchdogExpired, "The complete two-chapter conversion must finish within 90 seconds.")
            let final = try result.snapshot()
            player.finishStreaming(snapshot: final)
            XCTAssertEqual(final.chaptersCompleted, 2)
            XCTAssertFalse(usedSystem)
            XCTAssertFalse(player.isUsingSpeechFallback)
        } catch {
            control.cancel()
            player.stop()
            conversion.cancel()
            _ = await conversion.result
            XCTAssertFalse(watchdogExpired, "The conversion exceeded its 90-second watchdog.")
            throw error
        }
    }

    private func waitUntil(timeout: TimeInterval, predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(predicate(), "Transport must resolve within \(timeout) seconds.")
        if !predicate() { throw ControlsFailure.timeout }
    }

    private func tap(_ identifier: String, in view: UIView) throws {
        let button = try XCTUnwrap(descendants(view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == identifier })
        XCTAssertTrue(button.isEnabled)
        let started = ProcessInfo.processInfo.systemUptime
        button.sendActions(for: .touchUpInside)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5,
                          "A transport tap must not block the main actor.")
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

private enum ControlsFailure: Error { case timeout }

private final class ControlsFileManager: FileManager, @unchecked Sendable {
    private let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func url(for directory: SearchPathDirectory, in domain: SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL { root }
}
#endif
