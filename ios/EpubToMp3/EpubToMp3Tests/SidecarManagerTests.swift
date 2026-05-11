#if canImport(AppKit)
import XCTest
@testable import EpubToMp3

final class SidecarManagerTests: XCTestCase {

    /// `pickFreePort` is the load-bearing primitive of the sidecar
    /// boot path. We don't actually launch the binary here — that's an
    /// integration test that requires the PyInstaller artefact — but
    /// we do verify the kernel hands us a usable, ephemeral port and
    /// that two consecutive calls give back two distinct numbers in
    /// the ephemeral range.
    func testPicksFreeEphemeralPort() throws {
        let p1 = try SidecarManager.pickFreePort()
        let p2 = try SidecarManager.pickFreePort()
        XCTAssertGreaterThanOrEqual(p1, 1024)
        XCTAssertGreaterThanOrEqual(p2, 1024)
        XCTAssertNotEqual(p1, p2,
            "pickFreePort returned the same port twice; the kernel is supposed to rotate ephemeral ports between bind(0) calls.")
    }

    /// The locator must not crash, regardless of whether the sidecar
    /// is embedded in the host app bundle. Either outcome is valid:
    ///   - On a freshly-built macOS bundle (post `mise run mac:build`)
    ///     the sidecar lives at Contents/Resources/epub-to-mp3-server.
    ///   - On a CI test bundle without the post-build phase, the
    ///     locator returns nil and the app falls back to remote-only.
    /// The behaviour we *do* want pinned is: when a URL is returned,
    /// it points at an executable file inside the host bundle.
    func testLocateBundledBinaryNeverCrashesAndReturnsExecutableWhenPresent() {
        guard let url = SidecarManager.locateBundledBinary() else {
            // Acceptable on minimal/test bundles. The function just
            // must not have crashed.
            return
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path),
                      "locator returned \(url.path) but it isn't executable")
        XCTAssertTrue(url.path.contains(".app/Contents/Resources/"),
                      "locator returned a path outside the host bundle: \(url.path)")
    }
}
#endif
