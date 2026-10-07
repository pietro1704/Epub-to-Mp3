import XCTest
@testable import EpubToMp3

#if os(macOS)
import AppKit
import AVFoundation
import CryptoKit

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

    @MainActor
    func testSidebarNavigationRowsUseLabelWidthInsteadOfFillingSidebar() throws {
        let suiteName = "MacSidebarSizing.\(UUID().uuidString)"
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
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()

        let sidebar = root.splitViewItems[0].viewController.view
        func buttons(in view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons(in:))
        }
        let rows = buttons(in: sidebar).filter { (0...2).contains($0.tag) }
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertLessThanOrEqual(
                row.frame.width,
                row.fittingSize.width + 1,
                "Sidebar row should size to its icon and label, not leave an empty trailing button area."
            )
        }
    }

    @MainActor
    func testLocalConversionFinalizationPersistsJobAndKeepsCompleteProgressVisible() throws {
        let suiteName = "MacConversionFinish.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let book = BookEntity(
            id: suiteName,
            title: "Conversion completion fixture",
            bookmark: Data([1]),
            displayFilename: "fixture.epub",
            addedAt: Date()
        )
        let libraryKey = "library.\(suiteName)"
        defaults.set(try JSONEncoder().encode([book]), forKey: libraryKey)
        let library = LibraryStore(defaults: defaults, defaultsKey: libraryKey)
        let player = AudioPlayer(
            resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults))
        )
        let detail = MacBookDetailViewController(
            book: book,
            library: library,
            settings: AppSettings(defaults: defaults),
            player: player,
            playerPresentation: PlayerPresentation(defaults: defaults),
            onRead: { _ in },
            onShowJobs: {}
        )
        let detailView = detail.view
        detailView.layoutSubtreeIfNeeded()

        let jobID = UUID().uuidString
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName).output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let manifestJSON = Data("""
        {"manifest":{"jobId":"\(jobID)","title":"Conversion completion fixture","author":"Test","chapters":[{"title":"Chapter 1","filename":"chapter.mp3","textChars":8000,"sourceIndex":0}],"cover":null}}
        """.utf8)
        let result = RustConversionCoordinator.Result(
            jobID: jobID,
            manifestJSON: manifestJSON,
            outputDirectory: outputDirectory
        )

        let snapshot = try detail.finalizeLocalConversion(result)

        XCTAssertTrue(snapshot.isTerminal)
        XCTAssertEqual(snapshot.chaptersCompleted, 1)
        XCTAssertEqual(library.books.first?.lastJobId, jobID)
        let restoredLibrary = LibraryStore(defaults: defaults, defaultsKey: libraryKey)
        XCTAssertEqual(restoredLibrary.books.first?.lastJobId, jobID)

        func findProgressLabel(in view: NSView) -> NSTextField? {
            if let label = view as? NSTextField,
               label.accessibilityIdentifier() == "bookDetail.progress" {
                return label
            }
            return view.subviews.lazy.compactMap(findProgressLabel(in:)).first
        }
        let progressLabel = try XCTUnwrap(findProgressLabel(in: detailView))
        XCTAssertEqual(
            progressLabel.stringValue,
            L10n.string("bookDetail.progressPercent", 100)
        )
    }

    @MainActor
    func testOptInResumeCompletedChristieBookInMacAppWithoutChangingAudio() async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_RESUME_EXISTING_CHRISTIE_JOB"] == "1" else {
            throw XCTSkip("Set EPUB2MP3_RESUME_EXISTING_CHRISTIE_JOB=1 to resume the saved full-book conversion.")
        }

        let jobID = "EE78A887-F360-48E4-8D8F-E9FDF2A2E00B"
        let bookID = "55417053355de78768a0823d3cd203fd"
        let bookURL = URL(fileURLWithPath:
            NSHomeDirectory() + "/Library/Application Support/EpubToMp3/ImportedBooks/" +
                bookID + "/E não sobrou nenhum (Agatha Christie [Christie, Agatha]) " +
                "(z-library.sk, 1lib.sk, z-lib.sk).epub"
        )
        let outputDirectory = URL(fileURLWithPath:
            NSHomeDirectory() + "/Library/Application Support/EpubToMp3/RustConversions/" + jobID,
            isDirectory: true
        )
        let jobRecordURL = outputDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".jobs/\(jobID).json")
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.isReadableFile(atPath: bookURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: jobRecordURL.path))
        let previousJob = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: jobRecordURL)) as? [String: Any]
        )
        let previousState = try XCTUnwrap(previousJob["state"] as? String)
        XCTAssertTrue(["running", "completed"].contains(previousState))

        let mp3URLs = try fileManager.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let chapterPrefixes = Set(mp3URLs.compactMap { url -> Int? in
            guard !url.lastPathComponent.contains(".cover-") else { return nil }
            return Int(url.lastPathComponent.prefix(4))
        })
        XCTAssertEqual(chapterPrefixes, Set(1...113), "Every chapter audio file must exist before resume.")

        func audioFingerprint() throws -> Data {
            var input = Data()
            for url in mp3URLs {
                input.append(Data(url.lastPathComponent.utf8))
                input.append(try Data(contentsOf: url))
            }
            return Data(SHA256.hash(data: input))
        }
        let originalAudioFingerprint = try audioFingerprint()

        let result: RustConversionCoordinator.Result
        if previousState == "running" {
            result = try await RustConversionCoordinator().convert(
                bookURL: bookURL,
                jobID: jobID,
                chapterStart: -1,
                chapterEnd: -1
            )
        } else {
            let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            let response = try JSONSerialization.data(withJSONObject: ["manifest": manifest])
            result = RustConversionCoordinator.Result(
                jobID: jobID,
                manifestJSON: response,
                outputDirectory: outputDirectory
            )
        }
        let snapshot = try result.snapshot()

        XCTAssertEqual(snapshot.chaptersTotal, 113)
        XCTAssertEqual(snapshot.chaptersCompleted, 113)
        XCTAssertEqual(snapshot.playableChapters.count, 113)
        XCTAssertEqual(try audioFingerprint(), originalAudioFingerprint, "Resume must not rewrite existing chapter audio.")
        let resumedMP3Names = try fileManager.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "mp3" }.map(\.lastPathComponent)
        XCTAssertEqual(Set(resumedMP3Names), Set(mp3URLs.map(\.lastPathComponent)))
        let jobRecord = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: jobRecordURL)) as? [String: Any]
        )
        XCTAssertEqual(jobRecord["state"] as? String, "completed")
        XCTAssertTrue(fileManager.fileExists(atPath: outputDirectory.appendingPathComponent("manifest.json").path))

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "group.com.pietrocode.epubtomp3"))
        let library = LibraryStore(defaults: defaults)
        let book = try XCTUnwrap(library.books.first(where: { $0.id == bookID }))
        let detail = MacBookDetailViewController(
            book: book,
            library: library,
            settings: AppSettings(defaults: defaults),
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults))),
            playerPresentation: PlayerPresentation(defaults: defaults),
            onRead: { _ in },
            onShowJobs: {}
        )
        let detailView = detail.view
        detailView.layoutSubtreeIfNeeded()
        let terminalSnapshot = try detail.finalizeLocalConversion(result)
        XCTAssertTrue(terminalSnapshot.isTerminal)
        XCTAssertEqual(library.books.first(where: { $0.id == bookID })?.lastJobId, jobID)
        XCTAssertEqual(LibraryStore(defaults: defaults).books.first(where: { $0.id == bookID })?.lastJobId, jobID)

        func progressLabel(in view: NSView) -> NSTextField? {
            if let label = view as? NSTextField,
               label.accessibilityIdentifier() == "bookDetail.progress" {
                return label
            }
            return view.subviews.lazy.compactMap(progressLabel(in:)).first
        }
        XCTAssertEqual(
            try XCTUnwrap(progressLabel(in: detailView)).stringValue,
            L10n.string("bookDetail.progressPercent", 100)
        )
    }
}
#endif
