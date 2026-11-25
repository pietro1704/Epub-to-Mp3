import Foundation

/// The Application Support folder that app-owned stores build on.
/// Unit tests run inside the app host, so under XCTest the default file
/// manager resolves to a temporary folder instead of the listener's library
/// (MAC-TESTS-OTHER-STORES-ISOLATION). An injected file manager is the
/// caller's own isolation and is honoured as is.
enum ApplicationSupportRoot {
    nonisolated static func url(fileManager: FileManager = .default,
                                underXCTest: Bool = EpubToMp3App.isRunningUnderXCTest()) -> URL {
        if underXCTest && fileManager === FileManager.default {
            return fileManager.temporaryDirectory
                .appendingPathComponent("EpubToMp3-XCTest-ApplicationSupport", isDirectory: true)
        }
        return (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false))
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
