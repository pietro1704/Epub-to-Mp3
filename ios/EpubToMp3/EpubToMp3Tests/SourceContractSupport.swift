import XCTest

/// Shared helper for "source contract" tests that assert against the
/// checked-out repo's own source files (Swift, plist, project.yml, …) by
/// reading them straight off disk relative to `#filePath`.
///
/// That only works when the test process can see the Mac's checkout —
/// true on Simulator (shares the host filesystem) and in CI, but never on
/// a physical device: the device's app sandbox has no path back to
/// `/Users/.../Epub-to-Mp3/...`, so `String(contentsOf:)` throws
/// `NSCocoaErrorDomain Code=260` ("arquivo não existe") for every one of
/// these tests when run on-device. This project tests exclusively on a
/// physical iPhone (see CLAUDE.md "Local iOS Simulator Safety" — Simulator
/// boots are avoided on this Intel Mac), so skip instead of failing: the
/// assertions still run for real on Simulator/CI, and device runs stay
/// green instead of reporting dozens of environment-driven false failures.
extension XCTestCase {
    /// Reads `url` as UTF-8 text, or throws `XCTSkip` if it isn't reachable
    /// from the current sandbox (physical device).
    func readSourceFileIfAvailable(
        at url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "Host source file unreachable from this sandbox (likely a physical device run): \(url.path). Run via Simulator or CI to exercise this contract.",
                file: file,
                line: line
            )
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `Data`-returning counterpart, for plist/binary source contracts.
    func readSourceDataIfAvailable(
        at url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "Host source file unreachable from this sandbox (likely a physical device run): \(url.path). Run via Simulator or CI to exercise this contract.",
                file: file,
                line: line
            )
        }
        return try Data(contentsOf: url)
    }
}
