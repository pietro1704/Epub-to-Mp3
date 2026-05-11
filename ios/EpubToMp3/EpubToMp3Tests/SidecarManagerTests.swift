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

    /// Regression: when the sidecar child process dies, the manager
    /// must run its `terminationHandler`, push state back to `.idle`,
    /// and call `onSidecarDied`. Without this, the rest of the app
    /// keeps polling a dead loopback port (the original symptom was
    /// hundreds of "Connection refused" lines aimed at 127.0.0.1:NNNN).
    ///
    /// We don't spawn the real PyInstaller binary here — that would
    /// drag in a 17–30 s cold start. Instead we mimic the manager's
    /// process bookkeeping with `/bin/sleep`, attach the same kind
    /// of terminationHandler the production code uses, and assert
    /// the handler fires when we SIGKILL the child.
    func testTerminationHandlerFiresWhenChildDies() throws {
        let didFire = XCTestExpectation(description: "terminationHandler fires")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        proc.terminationHandler = { _ in
            didFire.fulfill()
        }
        try proc.run()
        // Give the child a beat to start so the kill below doesn't race.
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(proc.isRunning, "child must be alive before we kill it")

        kill(proc.processIdentifier, SIGKILL)
        wait(for: [didFire], timeout: 2.0)
        XCTAssertFalse(proc.isRunning,
                       "child should be reaped after termination handler runs")
    }

    /// Regression: `SidecarManager.onSidecarDied` exists as a public
    /// extension point on the manager so the host app can clear stale
    /// URLs and re-spawn. Closure assignment must round-trip and the
    /// type must be the documented `(@MainActor () -> Void)?`.
    @MainActor
    func testOnSidecarDiedCallbackIsConfigurable() {
        let manager = SidecarManager()
        var fired = false
        manager.onSidecarDied = {
            fired = true
        }
        // Invoke directly — we are validating the wiring contract,
        // not the underlying Process termination.
        manager.onSidecarDied?()
        XCTAssertTrue(fired,
                      "host must be able to install a callback for sidecar death")
    }

}
#endif
