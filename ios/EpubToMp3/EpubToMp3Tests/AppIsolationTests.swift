import XCTest
@testable import EpubToMp3

/// TEST-ISOLATION-LIBRARY: with the launch isolation active nothing may reach the real installation
/// (home directories, library/imported books/caches/models, defaults, the widget App Group), and
/// deactivating restores the process exactly. Normal launches never activate it.
final class AppIsolationTests: XCTestCase {
    override func tearDown() {
        AppIsolation.deactivate()
        super.tearDown()
    }

    func testOnlyTheLaunchArgumentActivatesIt() {
        XCTAssertNil(AppIsolation.activateIfRequested(arguments: ["EpubToMp3", "-AppleLanguages", "(en)"]))
        XCTAssertFalse(AppIsolation.isActive)
    }

    /// UI tests that use the fixture also reset reading progress and run on real devices: the fixture alone must
    /// isolate the launch, so no test can forget to ask for it.
    func testTheUITestFixtureLaunchIsIsolated() {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolation-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let root = AppIsolation.activateIfRequested(arguments: ["EpubToMp3", "-uiTestFixture"],
                                                    temporaryDirectory: temporary, redirectHome: false)

        XCTAssertNotNil(root, "-uiTestFixture must never run against the real installation")
        XCTAssertTrue(AppIsolation.isActive)
    }

    /// Without moving HOME (always the case on iOS) every store that resolves its own folder must still land in
    /// the throwaway home, and deactivating must give the real folders back.
    func testIsolationKeepsEveryAppDirectoryInTheThrowawayHome() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolation-directories-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let directories: [FileManager.SearchPathDirectory] = [
            .documentDirectory, .applicationSupportDirectory, .cachesDirectory, .libraryDirectory,
        ]
        let real = directories.map { FileManager.default.urls(for: $0, in: .userDomainMask) }

        let root = AppIsolation.activate(temporaryDirectory: temporary, redirectHome: false)
        let prefix = root.resolvingSymlinksInPath().path + "/"

        for directory in directories {
            let listed = try XCTUnwrap(FileManager.default.urls(for: directory, in: .userDomainMask).first)
            let resolved = try FileManager.default.url(for: directory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false)
            for url in [listed, resolved] {
                XCTAssertTrue(url.resolvingSymlinksInPath().path.hasPrefix(prefix),
                              "Directory \(directory.rawValue) still reaches the real installation")
            }
        }
        AppIsolation.deactivate()
        XCTAssertEqual(directories.map { FileManager.default.urls(for: $0, in: .userDomainMask) }, real)
    }

    /// An isolated launch sees an empty throwaway library, while iOS keeps the real files. That index must never
    /// be used to decide which book data is orphaned.
    @MainActor
    func testIsolatedLaunchNeverPrunesBookDataAgainstItsThrowawayIndex() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolation-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        AppIsolation.activate(temporaryDirectory: temporary, redirectHome: false)
        let suite = "isolation-prune-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        XCTAssertTrue(library.hasLoadedSuccessfully)
        let bookmarks = BookmarkStore(defaults: defaults, storageKey: "bookmarks")
        bookmarks.addBookmark(bookId: "real-book", chapterIndex: 0, chapterTitle: "Chapter")
        var pruned: [Set<String>] = []

        EpubToMp3App.pruneLibraryOrphans(library: library, bookmarkStore: bookmarks) { validIDs in
            pruned.append(validIDs)
            return 0
        }

        XCTAssertEqual(pruned, [], "The parsed-text cache was pruned against the throwaway index")
        XCTAssertEqual(bookmarks.bookmarks.map(\.bookId), ["real-book"])
    }

    /// iOS keeps the real home while isolated, so the imported book copies must be redirected on their own:
    /// otherwise a seeded UI test book is written next to the listener's books.
    func testIsolatedLaunchKeepsImportedBookFilesInTheThrowawayHome() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolation-imports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = AppIsolation.activate(temporaryDirectory: temporary, redirectHome: false)

        let imports = try LibraryImportFiles.importedBooksDirectory(fileManager: .default, baseDirectory: nil)

        XCTAssertTrue(imports.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
                      "Imported books must stay in the throwaway home, got \(imports.path)")
    }

    #if os(macOS)
    private func isUnder(_ url: URL, _ root: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }

    func testActivationRedirectsDirectoriesDefaultsAndTheAppGroupAndDeactivationRestoresThem() throws {
        let fileManager = FileManager.default
        let realHome = NSHomeDirectory()
        let probe = "app-isolation-probe-\(UUID().uuidString)"
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("isolation-test-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        let root = AppIsolation.activate(temporaryDirectory: temporary, redirectHome: false)
        XCTAssertTrue(AppIsolation.isActive)
        XCTAssertTrue(isUnder(root, temporary))

        // Directories: the throwaway home exists with the standard layout; the home-relative redirection itself
        // (HOME / CFFIXED_USER_HOME, applied once per launch) is proven end to end by scripts/verify_isolated_launch.sh.
        for sub in ["Library/Application Support", "Library/Caches", "Documents", "GroupContainer"] {
            XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent(sub).path), sub)
        }
        let overrides = AppIsolation.environmentOverrides(home: root)
        XCTAssertEqual(overrides["HOME"], root.path)
        XCTAssertEqual(overrides["CFFIXED_USER_HOME"], root.path)

        // Defaults: every `UserDefaults.standard` call site (settings, reading/session state, library index) is the
        // throwaway suite, never the real application domain.
        UserDefaults.standard.set("written-while-isolated", forKey: probe)
        XCTAssertEqual(UserDefaults.standard.string(forKey: probe), "written-while-isolated")
        XCTAssertNil(CFPreferencesCopyAppValue(probe as CFString, kCFPreferencesCurrentApplication),
                     "A standard-defaults write reached the real application domain")

        // The widget App Group: defaults and container are throwaway too.
        let group = try XCTUnwrap(UserDefaults(suiteName: AppIsolation.appGroupID))
        group.set("group-while-isolated", forKey: probe)
        XCTAssertNil(CFPreferencesCopyAppValue(probe as CFString, AppIsolation.appGroupID as CFString),
                     "A group-defaults write reached the real App Group")
        let container = try XCTUnwrap(fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppIsolation.appGroupID))
        XCTAssertTrue(isUnder(container, root))

        // Deactivating gives the process back unchanged and removes the throwaway data.
        AppIsolation.deactivate()
        XCTAssertFalse(AppIsolation.isActive)
        XCTAssertEqual(NSHomeDirectory(), realHome, "The test never redirected the home")
        XCTAssertNil(UserDefaults.standard.string(forKey: probe), "The isolated value must not survive in the real defaults")
        XCTAssertFalse(fileManager.fileExists(atPath: root.path))
    }

    func testTheSettingsSourceDefersToTheActiveIsolation() {
        AppIsolation.activate(temporaryDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("isolation-test-\(UUID().uuidString)"))
        XCTAssertTrue(SettingsDefaultsSource.resolve(arguments: []) === UserDefaults.standard)
    }
    #endif

    /// New code must keep reaching defaults through `UserDefaults.standard` (isolated at runtime) and never through
    /// a named suite of the real app, or the isolation would silently stop covering it.
    func testNoProductionCodeOpensAnotherRealDefaultsSuite() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("UserDefaults(suiteName:") {
                // Allowed: the shared App Group (redirected by the isolation) and the isolation's own suites.
                let allowed = line.contains("appGroupID") || line.contains("suiteName)") || line.contains("suiteName: suiteName")
                    || line.contains("defaultsSuiteName") || line.contains("groupDefaultsSuiteName")
                if !allowed { offenders.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))") }
            }
        }
        XCTAssertEqual(offenders, [], "Unisolated named defaults suites")
    }
}
