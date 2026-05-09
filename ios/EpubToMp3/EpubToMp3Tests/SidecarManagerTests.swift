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

    /// When the bundle has no embedded sidecar, locator must return
    /// nil rather than crash. Useful in tests + iOS where the binary
    /// is intentionally absent.
    func testLocateBundledBinaryReturnsNilWhenAbsent() {
        // Bundle.main in the test runner is the test bundle, not the
        // app — there's no embedded epub-to-mp3-server inside.
        XCTAssertNil(SidecarManager.locateBundledBinary())
    }
}
#endif
