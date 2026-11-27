import Foundation
import ObjectiveC

/// Launch-only isolation for UI tests and evidence captures.
///
/// With `-uiTestIsolatedSettings` the app must never read or write the real installation: not the library, the
/// imported books, caches, models, reading/session state, settings, nor the widget App Group. Instead of
/// threading a flag through every store, the process is redirected once, before anything touches disk:
///  - macOS: `HOME`/`CFFIXED_USER_HOME` point at a throwaway directory (deleted at every launch), so
///    Application Support, Caches, Documents and the Rust conversion roots all land there;
///  - iOS keeps the sandbox home: only imported book files are redirected (`LibraryImportFiles`), and stores that
///    resolve Application Support or Caches themselves still use the real folders;
///  - `UserDefaults.standard` returns a throwaway suite, so every present and future call site is covered;
///  - the App Group defaults suite and container are replaced by throwaway ones (widgets never see test data).
/// Normal launches never touch any of this.
enum AppIsolation {
    static let launchArgument = "-uiTestIsolatedSettings"
    static let defaultsSuiteName = "com.pietrocode.epubtomp3.uitest-isolated-settings"
    static let groupDefaultsSuiteName = "com.pietrocode.epubtomp3.uitest-isolated-group"
    static let rootDirectoryName = "EpubToMp3-isolated-home"
    static let appGroupID = "group.com.pietrocode.epubtomp3"

    /// The throwaway home while the isolation is active.
    private(set) static var root: URL?
    static var isActive: Bool { root != nil }

    private struct Saved {
        var environment: [String: String?]
        var realHome: String
        var standardIMP: IMP?
        var suiteIMP: IMP?
        var containerIMP: IMP?
    }
    private static var saved: Saved?
    private static var isolatedStandard: UserDefaults?

    /// Activates the isolation when `arguments` ask for it. Call first thing in `main`.
    @discardableResult
    static func activateIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        guard arguments.contains(launchArgument) else { return nil }
        return activate()
    }

    /// Redirects the process. Idempotent; returns the throwaway home.
    @discardableResult
    static func activate(temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                         redirectHome: Bool = true) -> URL {
        if let root { return root }
        let home = temporaryDirectory.appendingPathComponent(rootDirectoryName, isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: home)
        for sub in ["Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Logs",
                    "Documents", "GroupContainer"] {
            try? fileManager.createDirectory(at: home.appendingPathComponent(sub, isDirectory: true),
                                             withIntermediateDirectories: true)
        }
        var state = Saved(environment: [:], realHome: NSHomeDirectory(), standardIMP: nil, suiteIMP: nil, containerIMP: nil)
        #if os(macOS)
        // CoreFoundation caches the home it resolves, so the redirection cannot be undone in-process: it is applied
        // once per app launch (the regression test skips it and the launch script proves it end to end).
        if redirectHome {
            for (key, value) in environmentOverrides(home: home) {
                state.environment[key] = getenv(key).map { String(cString: $0) }
                setenv(key, value, 1)
            }
        }
        #endif
        // Throwaway defaults: emptied at every launch.
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        UserDefaults(suiteName: groupDefaultsSuiteName)?.removePersistentDomain(forName: groupDefaultsSuiteName)
        let suite = UserDefaults(suiteName: defaultsSuiteName) ?? UserDefaults()
        isolatedStandard = suite

        if let method = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")) {
            state.standardIMP = method_getImplementation(method)
            let block: @convention(block) (AnyObject) -> UserDefaults = { _ in AppIsolation.isolatedStandard ?? suite }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        if let method = class_getInstanceMethod(UserDefaults.self, NSSelectorFromString("initWithSuiteName:")) {
            let original = method_getImplementation(method)
            state.suiteIMP = original
            typealias Original = @convention(c) (AnyObject, Selector, NSString?) -> AnyObject?
            let call = unsafeBitCast(original, to: Original.self)
            let block: @convention(block) (AnyObject, NSString?) -> AnyObject? = { object, name in
                let mapped: NSString? = name as String? == appGroupID ? groupDefaultsSuiteName as NSString : name
                return call(object, NSSelectorFromString("initWithSuiteName:"), mapped)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        if let method = class_getInstanceMethod(FileManager.self,
                                                NSSelectorFromString("containerURLForSecurityApplicationGroupIdentifier:")) {
            state.containerIMP = method_getImplementation(method)
            let container = home.appendingPathComponent("GroupContainer", isDirectory: true)
            let block: @convention(block) (AnyObject, NSString) -> URL? = { _, _ in container }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        saved = state
        root = home
        return home
    }

    /// The variables that move Foundation's home-relative directories (and the Rust side's) into `home`.
    static func environmentOverrides(home: URL) -> [String: String] {
        ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
    }

    /// Restores the process. Used by the regression test; the app never deactivates.
    static func deactivate() {
        guard let state = saved, let home = root else { return }
        if let imp = state.standardIMP,
           let method = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")) {
            method_setImplementation(method, imp)
        }
        if let imp = state.suiteIMP,
           let method = class_getInstanceMethod(UserDefaults.self, NSSelectorFromString("initWithSuiteName:")) {
            method_setImplementation(method, imp)
        }
        if let imp = state.containerIMP,
           let method = class_getInstanceMethod(FileManager.self,
                                                NSSelectorFromString("containerURLForSecurityApplicationGroupIdentifier:")) {
            method_setImplementation(method, imp)
        }
        #if os(macOS)
        for (key, value) in state.environment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        #endif
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: home)
        isolatedStandard = nil
        saved = nil
        root = nil
    }
}
