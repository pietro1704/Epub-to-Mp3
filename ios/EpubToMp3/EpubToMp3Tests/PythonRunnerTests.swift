// PythonRunnerTests.swift

#if os(iOS) || os(macOS)

import XCTest
@testable import EpubToMp3

final class PythonRunnerTests: XCTestCase {
    #if os(macOS)
    func testMacUsesTheNativeRuntimeInsteadOfEmbeddedCPython() {
        XCTAssertFalse(PythonBridge.usesEmbeddedRuntime)
    }
    #endif

    func testRunnerExecutesQueuedWork() async throws {
        let value = try await PythonRunner.shared.callAsync(
            timeout: 1,
            label: "PythonRunner test"
        ) {
            42
        }

        XCTAssertEqual(value, 42)
    }
}

#endif
