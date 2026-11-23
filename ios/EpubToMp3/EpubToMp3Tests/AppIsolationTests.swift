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
