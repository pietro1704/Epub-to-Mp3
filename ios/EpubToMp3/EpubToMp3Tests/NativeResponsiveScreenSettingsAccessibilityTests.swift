#if os(iOS) || os(macOS)
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@testable import EpubToMp3

extension NativeResponsiveScreenTests {
#if os(iOS)
    func testSettingsRecycledCellsSpeakTheirCurrentVisibleContent() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = SettingsScreenController(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults), player: player, playbackClock: PlaybackClock(),
            diagnosticsSession: StreamingDiagnosticsSession())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        for section in [4, 3, 5, 0, 6] {
            for row in 0..<controller.tableView(controller.tableView, numberOfRowsInSection: section) {
                let index = IndexPath(row: row, section: section)
                controller.tableView.scrollToRow(at: index, at: .middle, animated: false)
                controller.tableView.layoutIfNeeded()
                guard let cell = controller.tableView.cellForRow(at: index),
                      let content = cell.contentConfiguration as? UIListContentConfiguration,
                      let title = content.text, let spoken = cell.accessibilityLabel else { continue }
                XCTAssertTrue(spoken.contains(title), "Visible title '\(title)' must not retain old spoken label '\(spoken)'")
            }
        }
    }
#endif

#if os(iOS)
#else
    func testSettingsMenuDestinationReusesInstalledController() throws {
        UserDefaults.standard.removeObject(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let root = MacAppKitRootController(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults))
        root.loadViewIfNeeded()
        root.showSettings(nil)
        let first = try XCTUnwrap(childControllers(root).compactMap { $0 as? MacSettingsViewController }.first)
        root.showSettings(nil)
        XCTAssertTrue(childControllers(root).contains { $0 === first })
    }
#endif

#if os(iOS)
#else
    func testReaderAppearanceControlsHaveSpokenNames() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let reader = MacReaderViewController(library: LibraryStore(defaults: defaults),
            settings: AppSettings(defaults: defaults), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = reader
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        let button = try XCTUnwrap(descendants(reader.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "reader.settings.toggle" })
        button.performClick(nil)
        let views = NSApp.windows.flatMap { $0.contentView.map(descendants) ?? [] }
        for (identifier, key) in [("font", "reader.font"), ("theme", "reader.theme"),
                                  ("layout", "reader.layout"), ("margin", "reader.margins"),
                                  ("kerning", "reader.kerning"), ("columns", "reader.columns")] {
            let popup = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityIdentifier() == "readerSettings.\(identifier)" })
            XCTAssertEqual(popup.accessibilityLabel(), L10n.string(key))
        }
        for key in ["readerSettings.decreaseFontSize", "readerSettings.increaseFontSize"] {
            XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.accessibilityLabel() == L10n.string(key) })
        }
    }
#endif

#if os(iOS)
#else
    func testMacTtsSettingsActionsPersistSelectionsWithoutChangingCapturedJobs() throws {
        // Use the suite owned by this test; teardown removes it and restores
        // shared reader/player preferences through the existing fixture.
        let settings = AppSettings(defaults: defaults)
        let target = SpeechModelLibraryTarget(
            language: "pt-BR", platform: "macos", androidAPI: 0,
            architecture: "x86_64", osVersion: "test",
            modelsRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("mac-settings-v3-\(UUID().uuidString)", isDirectory: true)
        )
        let inspected = try ConverterFFIAdapter().speechModelSnapshot(target: target)
        // This UI persistence fixture supplies ready state; real model loading
        // belongs to the opt-in native runtime acceptance, not this menu test.
        let entries = inspected.entries.map { entry -> SpeechModelSnapshot.Entry in
            guard entry.identity.modelID == "pt_BR-faber-medium" else { return entry }
            return .init(
                identity: entry.identity, presentation: entry.presentation,
                languageEvidence: entry.languageEvidence, distribution: entry.distribution,
                licence: entry.licence, compatibility: entry.compatibility,
                installation: .init(state: .installed, verifiedRevision: entry.identity.modelRevision,
                                    installedBytes: entry.distribution.downloadBytes),
                readiness: .init(state: .ready, activeRuntimeRevision: "native-ui-fixture", failure: nil),
                selection: .init(selectable: true, reasons: [])
            )
        }
        let snapshot = SpeechModelSnapshot(
            schemaVersion: inspected.schemaVersion,
            generatedFromCatalogRevision: inspected.generatedFromCatalogRevision,
            defaultSelection: inspected.defaultSelection, target: inspected.target, entries: entries
        )
        let speechModelState = SpeechModelLibraryViewState(snapshot: snapshot)
        let faberTitle = speechModelState.displayName(for: .selected(.piper))
        let controller = MacSettingsViewController(
            settings: settings,
            library: LibraryStore(defaults: defaults),
            speechModels: SpeechModelLibraryClient(initialSnapshot: snapshot, target: target)
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        // Installing a controller whose loadView starts at .zero can reset
        // the content dimensions; exercise a real, laid-out settings window.
        window.setContentSize(NSSize(width: 900, height: 700))
        controller.view.layoutSubtreeIfNeeded()
        let controls = descendants(controller.view)
        XCTAssertGreaterThan(controller.view.bounds.width, 0)
        XCTAssertGreaterThan(controller.view.bounds.height, 0)
        let primary = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityIdentifier() == "settings.tts.primary" })
        let secondary = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityIdentifier() == "settings.tts.secondary" })
        let online = try XCTUnwrap(controls.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "settings.tts.onlineConsent" })
        XCTAssertEqual(primary.titleOfSelectedItem, faberTitle)
        XCTAssertEqual(secondary.titleOfSelectedItem, L10n.string("settings.systemTts"))
        XCTAssertEqual(online.state, .off)
        XCTAssertNotNil(primary.window)

        primary.selectItem(withTitle: "Edge")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(primary.action), to: primary.target, from: primary))
        secondary.selectItem(withTitle: faberTitle)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.audioEngine, .edge)
        XCTAssertEqual(restored.ttsPreferences.secondary?.engine, "piper")
        XCTAssertFalse(restored.allowOnlineAudioFallback)

        online.performClick(nil)
        XCTAssertEqual(online.state, .on)
        XCTAssertTrue(AppSettings(defaults: defaults).allowOnlineAudioFallback)
        let captured = settings.conversionOptions
        primary.selectItem(withTitle: faberTitle)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(primary.action), to: primary.target, from: primary))
        XCTAssertNil(settings.secondaryAudioEngine, "A primary change must remove a duplicate secondary.")
        XCTAssertEqual(secondary.titleOfSelectedItem, L10n.string("settings.noSecondary"))
        secondary.selectItem(withTitle: "Edge")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        let final = AppSettings(defaults: defaults)
        XCTAssertEqual(final.audioEngine, .piper)
        XCTAssertEqual(final.ttsPreferences.secondary?.engine, "edge")
        XCTAssertTrue(final.allowOnlineAudioFallback)
        XCTAssertEqual(captured.ttsPreferences?.primary.engine, "edge")
        XCTAssertEqual(captured.ttsPreferences?.secondary?.engine, "piper")
        secondary.selectItem(withTitle: AudioEnginePreference.system.displayName)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        XCTAssertEqual(AppSettings(defaults: defaults).ttsPreferences.secondary?.engine, "system")
        XCTAssertEqual(settings.ttsPreferences.secondary?.engine, "system")
        XCTAssertEqual(captured.ttsPreferences?.secondary?.engine, "piper")
        let screenshot = FileManager.default.temporaryDirectory.appendingPathComponent("mac-tts-settings-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: screenshot) }
        try captureLiveWindow(window, to: screenshot)
    }
#endif

#if os(iOS)
#else
    func testSettingsControlsFitResizedWindowAndLastActionCanScrollIntoView() throws {
        let controller = MacSettingsViewController(settings: AppSettings(defaults: defaults),
                                                   library: LibraryStore(defaults: defaults))
        try verifyMacScrolling(controller, sizes: [NSSize(width: 520, height: 300), NSSize(width: 900, height: 700)],
                               lastTitle: L10n.string("settings.clearAllDownloads"))
    }
#endif
}
#endif
