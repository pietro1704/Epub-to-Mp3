import XCTest

/// Security regression tests for the app's transport-security exceptions.
///
/// The reader renders EPUB content with TextKit and does not embed a
/// WKWebView, and conversion runs in the embedded Rust core without a local
/// HTTP backend. The app therefore declares no ATS exception at all.
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

    func testInfoPlistDeclaresNoTransportSecurityException() throws {
        let source = try infoPlistSource()
        XCTAssertFalse(source.contains("NSAppTransportSecurity"),
                       "No local backend remains, so ATS must keep its secure defaults.")
        XCTAssertFalse(source.contains("NSAllowsLocalNetworking"))
        XCTAssertFalse(source.contains("NSAllowsArbitraryLoads"))
    }
}
