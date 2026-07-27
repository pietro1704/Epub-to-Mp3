import XCTest

/// Security regression tests for the app's transport-security exceptions.
///
/// The reader renders EPUB content with TextKit and does not embed a
/// WKWebView. The app therefore must not opt into arbitrary network loads in
/// web content; only the narrowly-scoped local-network exception is retained
/// for the local backend and macOS sidecar.
final class AppTransportSecurityTests: XCTestCase {
    private func infoPlistSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectRoot = testsDirectory.deletingLastPathComponent()
        let plistURL = projectRoot.appendingPathComponent("EpubToMp3/Resources/Info.plist")
        return try readSourceFileIfAvailable(at: plistURL)
    }

    func testInfoPlistDoesNotAllowArbitraryWebContentLoads() throws {
        let source = try infoPlistSource()
        XCTAssertFalse(
            source.contains("NSAllowsArbitraryLoadsInWebContent"),
            "The TextKit reader must not require a broad WKWebView ATS exception."
        )
    }

    func testInfoPlistRetainsOnlyLocalNetworkingException() throws {
        let source = try infoPlistSource()
        XCTAssertTrue(source.contains("NSAllowsLocalNetworking"))
        XCTAssertTrue(source.contains("<true/>"))
    }
}
