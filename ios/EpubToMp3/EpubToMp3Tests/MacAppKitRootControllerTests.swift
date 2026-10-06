import XCTest
@testable import EpubToMp3

#if os(macOS)
import AppKit
import AVFoundation

final class MacAppKitRootControllerTests: XCTestCase {
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
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
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
        let item = try XCTUnwrap(player.testHook_currentPlayerItem())
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
        XCTAssertTrue(player.testHook_currentPlayerItem() === item,
                      "Play after Pause must retain the actual AVPlayerItem, not reload the chapter.")
        XCTAssertEqual(player.testHook_currentPlayerItem()?.currentTime().seconds ?? -1,
                       pausedTime, accuracy: 0.5)
    }

    @MainActor
    func testMainMenuProvidesNativeFileEditViewWindowAndHelpMenus() throws {
        let mainMenu = EpubToMp3App.makeMainMenu()
        let menuTitles = mainMenu.items.compactMap { $0.submenu?.title }

        XCTAssertEqual(
            menuTitles,
            [
                L10n.string("app.name"),
                L10n.string("menu.file"),
                L10n.string("menu.edit"),
                L10n.string("menu.view"),
                L10n.string("menu.window"),
                L10n.string("menu.help"),
            ]
        )

        let fileMenu = try XCTUnwrap(mainMenu.items[1].submenu)
        XCTAssertTrue(fileMenu.items.contains { $0.title == L10n.string("menu.importBook") && $0.keyEquivalent == "o" })

        let viewMenu = try XCTUnwrap(mainMenu.items[3].submenu)
        XCTAssertTrue(viewMenu.items.contains { $0.title == L10n.string("nav.toggleSidebar") })
        XCTAssertTrue(viewMenu.items.contains { $0.title == L10n.string("menu.searchLibrary") && $0.keyEquivalent == "f" })
    }

    @MainActor
    func testToolbarSidebarItemCollapsesAndRestoresSidebarWithoutDetachingDetail() throws {
        let suiteName = "MacAppKitRootControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = MacAppKitRootController(
            settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library.\(suiteName)"),
            player: AudioPlayer(
                resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults))
            ),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks.\(suiteName)"),
            playerPresentation: PlayerPresentation(defaults: defaults)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = root
        root.configureWindowToolbar(window)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()

        let sidebarItem = try XCTUnwrap(
            window.toolbar?.items.first(where: {
                $0.itemIdentifier == MacAppKitRootController.sidebarToolbarItemIdentifier
            })
        )
        let detailView = root.splitViewItems[1].viewController.view
        XCTAssertFalse(root.splitViewItems[0].isCollapsed)
        XCTAssertNotNil(detailView.window)
        XCTAssertGreaterThan(detailView.frame.width, 0)

        XCTAssertTrue(
            NSApplication.shared.sendAction(sidebarItem.action!, to: sidebarItem.target, from: sidebarItem)
        )
        window.layoutIfNeeded()

        XCTAssertTrue(root.splitViewItems[0].isCollapsed)
        XCTAssertNotNil(detailView.window)
        XCTAssertGreaterThan(detailView.frame.width, 0)

        XCTAssertTrue(
            NSApplication.shared.sendAction(sidebarItem.action!, to: sidebarItem.target, from: sidebarItem)
        )
        window.layoutIfNeeded()

        XCTAssertFalse(root.splitViewItems[0].isCollapsed)
        XCTAssertEqual(root.splitViewItems.count, 2)
        XCTAssertNotNil(detailView.window)
        XCTAssertGreaterThan(detailView.frame.width, 0)
    }
}
#endif
