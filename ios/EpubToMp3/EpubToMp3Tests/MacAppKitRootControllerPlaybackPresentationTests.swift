import XCTest
@testable import EpubToMp3

#if os(macOS)
import AppKit
import AVFoundation
import CryptoKit

extension MacAppKitRootControllerTests {
    @MainActor
    func testExpandedMacPlayerDisplaysResolvedInstalledVoiceName() throws {
        let id = "MacActiveVoice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { defaults.removePersistentDomain(forName: id) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard)
        defer { player.stop() }
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data(#"{"jobId":"voice-fixture","state":"running","engine":"system","voice":"Luciana (installed.luciana)"}"#.utf8))
        player.setSnapshot(snapshot)
        let controller = MacFullPlayerViewController(player: player,
            library: LibraryStore(defaults: defaults, defaultsKey: "library"),
            presentation: PlayerPresentation(defaults: defaults), onStartPlayback: {})
        func status(in view: NSView) -> NSTextField? {
            if let label = view as? NSTextField, label.accessibilityIdentifier() == "fullPlayer.chapterAndVoice" { return label }
            return view.subviews.lazy.compactMap { status(in: $0) }.first
        }
        let label = try XCTUnwrap(status(in: controller.view))
        XCTAssertTrue(label.stringValue.contains("Luciana"))
        XCTAssertFalse(label.stringValue.contains("installed.luciana"), "Implementation identifiers stay in diagnostics")
    }

    @MainActor
    func testSpeedMenuUsesRequestedRatesAndAppliesSelection() async throws {
        let suiteName = "mac-speed-menu-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = AudioPlayer()
        player.setSnapshot(try JSONDecoder().decode(JobSnapshot.self, from:
            Data(#"{"jobId":"mac-speed-menu","state":"completed","bookTitle":"Speed menu"}"#.utf8)))
        let root = MacAppKitRootController(
            settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library"),
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults)
        )
        let window = NSWindow(contentViewController: root)
        window.setContentSize(NSSize(width: 900, height: 650))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 100_000_000)
        func rateButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.action == NSSelectorFromString("showRateMenu") {
                return button
            }
            return view.subviews.lazy.compactMap { rateButton(in: $0) }.first
        }
        let button = try XCTUnwrap(rateButton(in: root.view))
        XCTAssertTrue(button.isEnabled)
        // Close the real popup after AppKit enters its menu tracking loop.
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated { button.menu?.cancelTracking() }
        }
        RunLoop.main.add(timer, forMode: .common)
        button.performClick(nil)
        let menu = try XCTUnwrap(button.menu)
        XCTAssertEqual(menu.items.map(\.title), ["0.75x", "1x", "1.25x", "1.5x", "1.75x", "2x", "2.5x", "3x"])
        for (index, expected) in PlaybackRate.primaryRates.enumerated() {
            menu.performActionForItem(at: index)
            XCTAssertEqual(player.rate, expected)
        }
        player.setRate(.x080)
        let legacyTimer = Timer(timeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated { button.menu?.cancelTracking() }
        }
        RunLoop.main.add(legacyTimer, forMode: .common)
        button.performClick(nil)
        let selectedMenu = try XCTUnwrap(button.menu)
        XCTAssertEqual(selectedMenu.items.filter { $0.state == .on }.map(\.title), ["0.8x"])
        XCTAssertEqual(selectedMenu.items.filter { $0.title == "1x" }.count, 1)
        XCTAssertFalse(player.isPlaying, "Selecting a speed must not grant autoplay")
    }

    @MainActor
    func testPlayButtonResumesPausedAudioAtItsExactTime() async throws {
        let suiteName = "MacPauseResume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = UserDefaults.standard
        let readerKey = ReaderSessionState.currentlyReadingBookIDKey
        let playbackKey = AudioPlayer.currentBookIDDefaultsKey
        let ratioKey = AudioPlayer.readerCurrentPageRatioDefaultsKey
        let savedReader = standard.object(forKey: readerKey)
        let savedPlayback = standard.object(forKey: playbackKey)
        let chapterKey = AudioPlayer.currentChapterIndexDefaultsKey
        let savedChapter = standard.object(forKey: chapterKey)
        let widgetDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let savedWidgetBook = widgetDefaults?.object(forKey: "currentlyPlayingBookId")
        widgetDefaults?.set("", forKey: "currentlyPlayingBookId")
        let savedRatio = standard.object(forKey: ratioKey)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName).wav")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            standard.set(savedReader, forKey: readerKey)
            standard.set(savedPlayback, forKey: playbackKey)
            standard.set(savedChapter, forKey: chapterKey)
            widgetDefaults?.set(savedWidgetBook, forKey: "currentlyPlayingBookId")
            standard.set(savedRatio, forKey: ratioKey)
            try? FileManager.default.removeItem(at: audioURL)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 120_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 8_000)) * 0.05
        }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard)
        defer { player.stop() }
        // Prevent launch restoration from replacing the fixture with the
        // listener's real persisted audiobook while this test is suspended.
        standard.set(suiteName, forKey: readerKey)
        standard.set(suiteName, forKey: playbackKey)
        standard.set(0.0, forKey: ratioKey)
        let root = MacAppKitRootController(
            settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library"),
            player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults)
        )
        let rootView = root.view
        let snapshot = JobSnapshot(
            jobId: suiteName, state: "finished", bookTitle: "Pause fixture", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: "en",
            progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1,
            chapterProgress: [.init(index: 0, name: "Chapter", status: "completed",
                downloadUrl: audioURL.absoluteString, chars: 100, charsProcessed: 100,
                progressRatio: 1, durationSeconds: 15, startedAt: nil, completedAt: nil)],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
        player.play(snapshot: snapshot, startingAt: 0)
        player.resume()
        let item = try XCTUnwrap(player.services.queue.player?.currentItem)
        for _ in 0..<100 where item.status == .unknown {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard item.status == .readyToPlay else {
            return XCTFail("Local audio did not become ready: \(String(describing: item.error))")
        }
        let sought = await item.seek(to: CMTime(seconds: 7, preferredTimescale: 600),
                                     toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(sought)
        func playButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.action == NSSelectorFromString("togglePlayback") {
                return button
            }
            return view.subviews.lazy.compactMap { playButton(in: $0) }.first
        }
        let button = try XCTUnwrap(playButton(in: rootView))
        player.resume()
        button.performClick(nil)
        XCTAssertTrue(player.hasPausedPlaybackToResume)
        let pausedTime = item.currentTime().seconds
        XCTAssertGreaterThanOrEqual(pausedTime, 7)
        button.performClick(nil)
        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.services.queue.player?.currentItem === item,
                      "Play after Pause must retain the actual AVPlayerItem, not reload the chapter.")
        XCTAssertEqual(player.services.queue.player?.currentItem?.currentTime().seconds ?? -1,
                       pausedTime, accuracy: 0.5)
    }
}
#endif
