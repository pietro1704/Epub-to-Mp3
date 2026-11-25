import Foundation

/// The Application Support folder that app-owned stores build on.
/// Unit tests run inside the app host, so under XCTest the default file
/// manager resolves to a temporary folder instead of the listener's library
/// (MAC-TESTS-OTHER-STORES-ISOLATION). An injected file manager is the
/// caller's own isolation and is honoured as is.
enum ApplicationSupportRoot {
    nonisolated static func url(fileManager: FileManager = .default,
                                underXCTest: Bool = isRunningUnderXCTest()) -> URL {
        if underXCTest && fileManager === FileManager.default {
            return fileManager.temporaryDirectory
                .appendingPathComponent("EpubToMp3-XCTest-ApplicationSupport", isDirectory: true)
        }
        return (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false))
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Whether the process hosts XCTest. It lives here, with Foundation only, so the
    /// Swift package that compiles the stores without the app entry point can use it.
    nonisolated static func isRunningUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        classLookup: (String) -> AnyClass? = NSClassFromString
    ) -> Bool {
        environment.keys.contains("XCTestConfigurationFilePath")
            || environment.keys.contains("XCTestSessionIdentifier")
            || environment.keys.contains("XCTestBundlePath")
            || classLookup("XCTest.XCTestCase") != nil
            || classLookup("XCTestCase") != nil
    }
}
