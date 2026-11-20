import XCTest
#if os(macOS)
import AppKit
#endif
@testable import EpubToMp3

final class AppLaunchEnvironmentTests: XCTestCase {
    #if os(macOS)
    @MainActor
    func testMacXCTestHostStartsWithoutADockIcon() {
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .accessory)
    }
    #endif

    @MainActor
    func testDetectsXCTestConfigurationFilePathEvenWhenEmpty() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(environment: [
            "XCTestConfigurationFilePath": ""
        ]))
    }

    @MainActor
    func testDetectsXcode26XCTestSessionIdentifier() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(environment: [
            "XCTestSessionIdentifier": "session-id"
        ]))
    }

    @MainActor
    func testDetectsInjectedXCTestBundlePath() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(environment: [
            "XCTestBundlePath": "Contents/PlugIns/EpubToMp3Tests.xctest"
        ]))
    }

    @MainActor
    func testDetectsLoadedXCTestClassWhenEnvironmentIsSanitized() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(
            environment: [:],
            classLookup: { name in name == "XCTest.XCTestCase" ? XCTestCase.self : nil }
        ))
    }

    @MainActor
    func testDoesNotDetectRegularLaunchEnvironment() {
        XCTAssertFalse(EpubToMp3App.isRunningUnderXCTest(
            environment: [
                "HOME": "/tmp",
                "PATH": "/usr/bin"
            ],
            classLookup: { _ in nil }
        ))
    }
}
