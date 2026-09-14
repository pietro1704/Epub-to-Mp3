#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

final class SettingsStorageActionTests: XCTestCase {
    @MainActor
    func testTemporaryAudioActionPresentsOnlyTemporaryRemovalConfirmation() async throws {
        try await assertConfirmation(
            cellLabel: "settings.clearTemporaryAudio",
            title: "settings.clearTemporaryAudioConfirmTitle",
            message: "settings.clearTemporaryAudioConfirmMessage")
    }

    @MainActor
    func testAllDownloadsActionPresentsProtectedDownloadRemovalConfirmation() async throws {
        try await assertConfirmation(
            cellLabel: "settings.clearAllDownloads",
            title: "settings.clearAllDownloadsConfirmTitle",
            message: "settings.clearAllDownloadsConfirmMessage")
    }

    @MainActor
    private func assertConfirmation(cellLabel: String, title: String, message: String) async throws {
        let identifier = "StorageAction-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let savedWidgetBook = widget?.object(forKey: "currentlyPlayingBookId")
        widget?.set("", forKey: "currentlyPlayingBookId")
        defer {
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            widget?.set(savedWidgetBook, forKey: "currentlyPlayingBookId")
            defaults.removePersistentDomain(forName: identifier)
        }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let controller = SettingsScreenController(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults), player: player, playbackClock: PlaybackClock(),
            diagnosticsSession: StreamingDiagnosticsSession())
        let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        defer {
            // Never invoke an alert action: dismissal cannot execute deletion.
            controller.presentedViewController?.dismiss(animated: false)
            controller.viewDidDisappear(false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        let expectedLabel = L10n.string(cellLabel)
        let indexPath = try XCTUnwrap((0..<controller.numberOfSections(in: controller.tableView)).flatMap { section in
            (0..<controller.tableView(controller.tableView, numberOfRowsInSection: section)).map {
                IndexPath(row: $0, section: section)
            }
        }.first { index in
            let cell = controller.tableView(controller.tableView, cellForRowAt: index)
            return (cell.contentConfiguration as? UIListContentConfiguration)?.text == expectedLabel
        })
        controller.tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
        controller.tableView.layoutIfNeeded()
        let visibleCell = try XCTUnwrap(controller.tableView.cellForRow(at: indexPath))
        XCTAssertEqual((visibleCell.contentConfiguration as? UIListContentConfiguration)?.text, expectedLabel)
        controller.tableView(controller.tableView, didSelectRowAt: indexPath)
        for _ in 0..<100 {
            if controller.presentedViewController is UIAlertController { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let alert = try XCTUnwrap(controller.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, L10n.string(title),
                       "The confirmation must describe the removal scope selected in Settings.")
        XCTAssertEqual(alert.message, L10n.string(message))
        XCTAssertEqual(alert.actions.filter { $0.style == .destructive }.map(\.title),
                       [L10n.string("settings.clearCacheConfirmButton")])
        XCTAssertEqual(alert.actions.filter { $0.style == .cancel }.map(\.title),
                       [L10n.string("library.cancel")])
        // Inspect the real confirmation only. No protected or temporary audio
        // is created, removed, or used as a sacrificial test fixture.
        alert.dismiss(animated: false)
    }
}
#endif
