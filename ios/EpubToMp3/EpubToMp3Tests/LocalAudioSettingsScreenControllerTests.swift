#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

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

    @MainActor
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

        let managementIndexPath = IndexPath(row: 4, section: SettingsSection.storage.rawValue)
        let managementCell = controller.tableView(controller.tableView, cellForRowAt: managementIndexPath)
        XCTAssertEqual(managementCell.accessibilityIdentifier, "settings.manageDownloads")
        controller.tableView(controller.tableView, didSelectRowAt: managementIndexPath)
        XCTAssertTrue(navigation.topViewController is LocalAudioDownloadsScreenController)
    }

    @MainActor
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

    @MainActor
    func testRemovalActionsExistOnlyInStorageAndAdvancedHasNoDeletionAction() {
        let controller = makeSettingsController(settings: AppSettings(defaults: defaults))
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.tableView(controller.tableView,
            numberOfRowsInSection: SettingsSection.advanced.rawValue), 4)
        for key in ["settings.clearTemporaryAudio", "settings.clearAllDownloads", "settings.manageDownloads"] {
            let positions = (0..<controller.numberOfSections(in: controller.tableView)).flatMap { section in
                (0..<controller.tableView(controller.tableView, numberOfRowsInSection: section)).compactMap { row -> Int? in
                    let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: row, section: section))
                    return (cell.contentConfiguration as? UIListContentConfiguration)?.text == L10n.string(key) ? section : nil
                }
            }
            XCTAssertEqual(positions, [SettingsSection.storage.rawValue])
        }
    }

    @MainActor
    func testPerBookRemovalUpdatesOnlySuccessfulBookAndPreservesOtherData() async throws {
        try await assertPerBookRemoval(failure: nil)
    }

    @MainActor
    func testPerBookFailureAndCancellationKeepOfflineStateAndFiles() async throws {
        try await assertPerBookRemoval(failure: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        try await assertPerBookRemoval(failure: CancellationError())
    }

    @MainActor
    private func assertPerBookRemoval(failure: Error?) async throws {
        let firstID = UUID().uuidString, otherID = UUID().uuidString
        let books = [firstID, otherID].map { BookEntity(id: $0, title: $0, bookmark: Data([1]),
            displayFilename: "fixture.epub", addedAt: .now, cachedOffline: true) }
        defaults.set(try JSONEncoder().encode(books), forKey: "library.books.v1")
        let library = LibraryStore(defaults: defaults)
        let store = LocalAudioArtifactStore(root: root.appendingPathComponent(UUID().uuidString))
        var files: [String: URL] = [:]
        let bytes = Data(repeating: 0xB2, count: 64)
        for id in [firstID, otherID] {
            try await store.prepare(bookID: id, bookTitle: id, author: nil, chapters: [.init(index: 0, title: "Chapter")])
            let url = try await store.canonicalURL(bookID: id, chapterIndex: 0)
            try bytes.write(to: url)
            try await store.markAvailable(bookID: id, chapterIndex: 0)
            try await store.promote(bookID: id, chapterIndex: 0)
            files[id] = url
        }
        let protected = root.appendingPathComponent("source-and-model-fixture")
        try bytes.write(to: protected)
        let downloaded = try await store.downloadedBooks()
        let selected = try XCTUnwrap(downloaded.first { $0.bookID == firstID })
        let controller = LocalAudioDownloadsScreenController(library: library, artifactStore: store,
            removeAudio: { id in
                if let failure { throw failure }
                try await store.clearDownloadedAudio(bookID: id)
            })
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer {
            controller.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.loadViewIfNeeded()
        await controller.removeDownloadedAudio(for: selected)
        XCTAssertEqual(library.books.first { $0.id == firstID }?.cachedOffline, failure != nil)
        XCTAssertEqual(library.books.first { $0.id == otherID }?.cachedOffline, true)
        XCTAssertEqual(FileManager.default.fileExists(atPath: try XCTUnwrap(files[firstID]).path), failure != nil)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files[otherID])), bytes)
        XCTAssertEqual(try Data(contentsOf: protected), bytes)
        if failure != nil && !(failure is CancellationError) {
            XCTAssertEqual((controller.presentedViewController as? UIAlertController)?.title,
                           L10n.string("settings.storageRemovalFailedTitle"))
        }
    }

    @MainActor
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
