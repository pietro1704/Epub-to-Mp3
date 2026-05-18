import XCTest
@testable import EpubToMp3

/// Security regression tests for `AppSettings.resolvedBaseURL`.
/// Verifies that the scheme allowlist rejects any non-http/https URL
/// so a malicious deep-link or QR code cannot redirect the backend
/// client to a `javascript:`, `file:`, or custom-scheme endpoint.
final class AppSettingsSecurityTests: XCTestCase {

    // MARK: - Helpers

    private func makeSettings(url: String) -> AppSettings {
        let s = AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        s.backendURL = url
        // Disable sidecar so resolvedBaseURL always uses backendURL
        s.useEmbeddedSidecar = false
        return s
    }

    // MARK: - Malicious schemes must be rejected (return nil)

    func test_javascriptScheme_isRejected() {
        let s = makeSettings(url: "javascript:alert(1)")
        XCTAssertNil(s.resolvedBaseURL)
    }

    func test_fileScheme_isRejected() {
        let s = makeSettings(url: "file:///etc/passwd")
        XCTAssertNil(s.resolvedBaseURL)
    }

    func test_dataScheme_isRejected() {
        let s = makeSettings(url: "data:text/html,<script>alert(1)</script>")
        XCTAssertNil(s.resolvedBaseURL)
    }

    func test_ftpScheme_isRejected() {
        let s = makeSettings(url: "ftp://evil.example.com/payload")
        XCTAssertNil(s.resolvedBaseURL)
    }

    func test_customScheme_isRejected() {
        let s = makeSettings(url: "myapp://callback")
        XCTAssertNil(s.resolvedBaseURL)
    }

    func test_bareSchemeMissingHost_isRejected() {
        // "http://" has an empty host — must be rejected
        let s = makeSettings(url: "http://")
        XCTAssertNil(s.resolvedBaseURL)
    }

    func test_emptyString_isRejected() {
        let s = makeSettings(url: "")
        XCTAssertNil(s.resolvedBaseURL)
    }

    func test_whitespaceOnly_isRejected() {
        let s = makeSettings(url: "   ")
        XCTAssertNil(s.resolvedBaseURL)
    }

    // MARK: - Valid HTTP/HTTPS URLs must pass through

    func test_httpLocalhost_isAccepted() {
        let s = makeSettings(url: "http://localhost:8000")
        let url = s.resolvedBaseURL
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "localhost")
    }

    func test_httpsRemote_isAccepted() {
        let s = makeSettings(url: "https://api.example.com")
        let url = s.resolvedBaseURL
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "https")
    }

    func test_trailingSlash_isStripped() {
        let s = makeSettings(url: "http://localhost:8000/")
        let url = s.resolvedBaseURL
        XCTAssertNotNil(url)
        XCTAssertFalse(url!.absoluteString.hasSuffix("/"))
    }

    func test_httpWithPath_isAccepted() {
        let s = makeSettings(url: "http://192.168.1.10:8000/api")
        XCTAssertNotNil(s.resolvedBaseURL)
    }
}
