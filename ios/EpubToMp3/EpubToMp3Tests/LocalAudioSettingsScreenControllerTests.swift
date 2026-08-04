#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class LocalAudioSettingsScreenControllerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-audio-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaultsSuiteName = "LocalAudioSettingsScreenControllerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        root = nil
        defaults = nil
        defaultsSuiteName = nil
    }

    func testSettingsExposesWiFiPolicyAndPerBookDownloadManagement() {
        let settings = AppSettings(defaults: defaults)
        let controller = makeSettingsController(settings: settings)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        let cellularCell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 1, section: 0)
        ) as? IOSSwitchCell
        XCTAssertEqual(cellularCell?.accessibilityIdentifier, "settings.allowCellularAudio")
        cellularCell?.toggleSwitch.isOn = true
        cellularCell?.toggleSwitch.sendActions(for: .valueChanged)
        XCTAssertTrue(settings.allowCellularAudioConversion)

        let managementIndexPath = IndexPath(row: 4, section: 3)
        let managementCell = controller.tableView(controller.tableView, cellForRowAt: managementIndexPath)
        XCTAssertEqual(managementCell.accessibilityIdentifier, "settings.manageDownloads")
        controller.tableView(controller.tableView, didSelectRowAt: managementIndexPath)
        XCTAssertTrue(navigation.topViewController is LocalAudioDownloadsScreenController)
    }

    func testDownloadedBookRemovalRequiresConfirmation() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: "Author",
            chapters: [.init(index: 0, title: "Chapter")]
        )
        let fileURL = try await store.canonicalURL(bookID: "book-id", chapterIndex: 0)
        try Data(repeating: 0xB2, count: 64).write(to: fileURL)
        try await store.markAvailable(bookID: "book-id", chapterIndex: 0)
        try await store.promote(bookID: "book-id", chapterIndex: 0)

        let controller = LocalAudioDownloadsScreenController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library.\(UUID().uuidString)"),
            artifactStore: store
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        await controller.refreshDownloadedBooks()

        let cell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        XCTAssertEqual(cell.accessibilityIdentifier, "settings.downloadedBook.book-id")
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))

        let alert = try XCTUnwrap(controller.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, L10n.string("settings.removeBookDownloadConfirmTitle"))
        XCTAssertTrue(alert.actions.contains { $0.style == .destructive })
    }

    private func makeSettingsController(settings: AppSettings) -> SettingsScreenController {
        SettingsScreenController(
            settings: settings,
            library: LibraryStore(defaults: defaults, defaultsKey: "library.\(UUID().uuidString)"),
            player: AudioPlayer(),
            playbackClock: PlaybackClock()
        )
    }
}
#endif
