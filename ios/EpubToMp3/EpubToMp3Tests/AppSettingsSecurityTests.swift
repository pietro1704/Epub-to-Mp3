import XCTest
@testable import EpubToMp3

/// Legacy endpoint values remain migration data. Native Apple runtime routing
/// always uses the embedded converter, including for valid HTTP endpoints.
final class AppSettingsSecurityTests: XCTestCase {

    // MARK: - Helpers

    private func makeSettings(url: String) -> AppSettings {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        s.backendURL = url
        XCTAssertEqual(s.backendURL, url)
        XCTAssertEqual(defaults.string(forKey: "backendURL"), url)
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

    // MARK: - Valid HTTP/HTTPS migration values remain inert

    func test_httpLocalhost_doesNotEnableRemoteRouting() {
        let s = makeSettings(url: "http://localhost:8000")
        let url = s.resolvedBaseURL
        XCTAssertNil(url)
    }

    func test_httpsRemote_doesNotEnableRemoteRouting() {
        let s = makeSettings(url: "https://api.example.com")
        let url = s.resolvedBaseURL
        XCTAssertNil(url)
    }

    func test_trailingSlash_doesNotEnableRemoteRouting() {
        let s = makeSettings(url: "http://localhost:8000/")
        let url = s.resolvedBaseURL
        XCTAssertNil(url)
        XCTAssertEqual(s.backendURL, "http://localhost:8000/")
    }

    func test_httpWithPath_doesNotEnableRemoteRouting() {
        let s = makeSettings(url: "http://192.168.1.10:8000/api")
        XCTAssertNil(s.resolvedBaseURL)
    }

    func testPersistedRemotePreferencesCannotRestoreRemoteRouting() throws {
        let suite = "test-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://legacy.example.com/api", forKey: "backendURL")
        defaults.set(false, forKey: "useEmbeddedRuntime")
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.useEmbeddedRuntime)
        XCTAssertEqual(settings.backendURL, "")
        XCTAssertNil(settings.resolvedBaseURL)
        XCTAssertFalse(settings.remoteBackendControlsEnabled)
        XCTAssertTrue(settings.canReadOffline)
        XCTAssertEqual(defaults.string(forKey: "backendURL"), "",
                       "The initializer clears the retired endpoint instead of restoring a transport.")
    }
}
