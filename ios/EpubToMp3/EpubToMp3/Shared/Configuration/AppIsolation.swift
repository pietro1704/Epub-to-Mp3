import Foundation
import ObjectiveC

/// Launch-only isolation for UI tests and evidence captures.
///
/// With `-uiTestIsolatedSettings`, or `-uiTestFixture` (which implies it), the app must never read or write the real installation: not the library, the
/// imported books, caches, models, reading/session state, settings, nor the widget App Group. Instead of
/// threading a flag through every store, the process is redirected once, before anything touches disk:
///  - macOS: `HOME`/`CFFIXED_USER_HOME` point at a throwaway directory (deleted at every launch), so
///    Application Support, Caches, Documents and the Rust conversion roots all land there;
///  - iOS keeps the sandbox home, so on both platforms `FileManager` also resolves Documents, Application
///    Support, Caches and Library inside the throwaway directory;
///  - `UserDefaults.standard` returns a throwaway suite, so every present and future call site is covered;
///  - the App Group defaults suite and container are replaced by throwaway ones (widgets never see test data).
/// Normal launches never touch any of this.
enum AppIsolation {
    static let launchArgument = "-uiTestIsolatedSettings"
    /// The in-memory library of the UI tests. They reset reading progress and run on real devices.
    static let fixtureLaunchArgument = "-uiTestFixture"
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
        var directoryListIMP: IMP?
        var directoryIMP: IMP?
    }
    private static var saved: Saved?
    private static var isolatedStandard: UserDefaults?

    /// Activates the isolation when `arguments` ask for it. Call first thing in `main`.
    @discardableResult
    static func activateIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments,
                                    temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                                    redirectHome: Bool = true) -> URL? {
        guard arguments.contains(launchArgument) || arguments.contains(fixtureLaunchArgument) else { return nil }
        return activate(temporaryDirectory: temporaryDirectory, redirectHome: redirectHome)
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
        redirectDirectories(into: home, saving: &state)
        saved = state
        root = home
        return home
    }

    private static let directoryListSelector = NSSelectorFromString("URLsForDirectory:inDomains:")
    private static let directorySelector =
        NSSelectorFromString("URLForDirectory:inDomain:appropriateForURL:create:error:")

    /// Stores resolve their own folders through `FileManager`, which moving HOME does not cover on iOS.
    private static func redirectDirectories(into home: URL, saving state: inout Saved) {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let folders: [UInt: URL] = [
            FileManager.SearchPathDirectory.documentDirectory.rawValue:
                home.appendingPathComponent("Documents", isDirectory: true),
            FileManager.SearchPathDirectory.applicationSupportDirectory.rawValue:
                library.appendingPathComponent("Application Support", isDirectory: true),
            FileManager.SearchPathDirectory.cachesDirectory.rawValue:
                library.appendingPathComponent("Caches", isDirectory: true),
            FileManager.SearchPathDirectory.libraryDirectory.rawValue: library,
        ]
        let user = FileManager.SearchPathDomainMask.userDomainMask.rawValue

        if let method = class_getInstanceMethod(FileManager.self, directoryListSelector) {
            let original = method_getImplementation(method)
            state.directoryListIMP = original
            typealias Original = @convention(c) (AnyObject, Selector, UInt, UInt) -> NSArray
            let call = unsafeBitCast(original, to: Original.self)
            let block: @convention(block) (AnyObject, UInt, UInt) -> NSArray = { object, directory, domain in
                if domain == user, let folder = folders[directory] { return [folder as NSURL] }
                return call(object, directoryListSelector, directory, domain)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        if let method = class_getInstanceMethod(FileManager.self, directorySelector) {
            let original = method_getImplementation(method)
            state.directoryIMP = original
            typealias Original = @convention(c)
                (AnyObject, Selector, UInt, UInt, NSURL?, ObjCBool, UnsafeMutableRawPointer?) -> NSURL?
            let call = unsafeBitCast(original, to: Original.self)
            let block: @convention(block)
                (AnyObject, UInt, UInt, NSURL?, ObjCBool, UnsafeMutableRawPointer?) -> NSURL? = {
                    object, directory, domain, appropriate, create, error in
                    if domain == user, let folder = folders[directory] { return folder as NSURL }
                    return call(object, directorySelector, directory, domain, appropriate, create, error)
                }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
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
        if let imp = state.directoryListIMP,
           let method = class_getInstanceMethod(FileManager.self, directoryListSelector) {
            method_setImplementation(method, imp)
        }
        if let imp = state.directoryIMP,
           let method = class_getInstanceMethod(FileManager.self, directorySelector) {
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
