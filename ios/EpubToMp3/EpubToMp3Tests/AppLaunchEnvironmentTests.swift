import XCTest
@testable import EpubToMp3

final class AppLaunchEnvironmentTests: XCTestCase {
    func testDetectsXCTestConfigurationFilePathEvenWhenEmpty() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(environment: [
            "XCTestConfigurationFilePath": ""
        ]))
    }

    func testDetectsXcode26XCTestSessionIdentifier() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(environment: [
            "XCTestSessionIdentifier": "session-id"
        ]))
    }

    func testDetectsInjectedXCTestBundlePath() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(environment: [
            "XCTestBundlePath": "Contents/PlugIns/EpubToMp3Tests.xctest"
        ]))
    }

    func testDetectsLoadedXCTestClassWhenEnvironmentIsSanitized() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(
            environment: [:],
            classLookup: { name in name == "XCTest.XCTestCase" ? XCTestCase.self : nil }
        ))
    }

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
