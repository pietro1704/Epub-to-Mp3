import Foundation
import XCTest
@testable import DeviceWorkflow

final class DeviceSelectionTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/unused-device-selection-root")

    func testExplicitAuditedClassesPreserveSelectionOrderAndDeviceIdentity() throws {
        let filters = ["EpubToMp3Tests/ReaderProgressStoreTests", "EpubToMp3Tests/ReaderViewportTransitionTests"]
        let options = try Options(arguments: ["test", "--device", "literal-device"], root: root,
                                  environment: ["IOS_TESTS": filters.joined(separator: ",")])
        XCTAssertEqual(options.testFilters, filters)
        XCTAssertEqual(options.expectedTestCount, 22)
        XCTAssertEqual(options.device, "literal-device")
        XCTAssertFalse(options.skipBuild)
    }

    func testExactMethodSelectorRemainsLiteral() throws {
        let selector = "EpubToMp3Tests/ReaderViewportTransitionTests/testCancelInvalidatesOutstandingToken"
        let options = try Options(arguments: ["test"], root: root, environment: ["IOS_TESTS": selector])
        XCTAssertEqual(options.testFilters, [selector])
        XCTAssertEqual(options.expectedTestCount, 1)
    }

    func testMixedDistinctClassAndMethodsCountOnlySelectedTests() throws {
        let filters = ["EpubToMp3Tests/ReaderViewportTransitionTests",
                       "EpubToMp3Tests/ReaderProgressStoreTests/testSaveAndReadRoundTrip",
                       "EpubToMp3Tests/ReaderProgressStoreTests/testReadMissingBookReturnsNil"]
        let options = try Options(arguments: ["test"], root: root,
                                  environment: ["IOS_TESTS": filters.joined(separator: ",")])
        XCTAssertEqual(options.expectedTestCount, 6)
        XCTAssertEqual(options.testFilters, filters)
    }

    func testMissingEmptyMalformedAndUnauditedSelectionsAreRejected() {
        XCTAssertThrowsError(try Options(arguments: ["test"], root: root, environment: [:]))
        for selector in ["", " ", ",", "EpubToMp3Tests", "EpubToMp3Tests/",
                         "EpubToMp3UITests/DeviceAcceptanceUITests", "EpubToMp3Tests/FaberNativeInferenceTests",
                         "EpubToMp3Tests/ReaderProgressStoreTests*", "Other/ReaderProgressStoreTests",
                         "EpubToMp3Tests/ReaderProgressStoreTests/", "EpubToMp3Tests/ReaderProgressStoreTests/test*",
                         "EpubToMp3Tests/ReaderProgressStoreTests/testSaveAndReadRoundTrip()",
                         "EpubToMp3Tests/ReaderProgressStoreTests/testSaveAndReadRoundTrip/extra",
                         "EpubToMp3Tests/ReaderProgressStoreTests/testTypo",
                         "EpubToMp3Tests/ReaderViewportTransitionTests,EpubToMp3Tests/ReaderProgressStoreTests/testTypo",
                         "EpubToMp3Tests/ReaderProgressStoreTests,EpubToMp3Tests/ReaderProgressStoreTests/testSaveAndReadRoundTrip",
                         "EpubToMp3Tests/ReaderProgressStoreTests/testSaveAndReadRoundTrip,EpubToMp3Tests/ReaderProgressStoreTests",
                         " EpubToMp3Tests/ReaderProgressStoreTests", "EpubToMp3Tests/ReaderProgressStoreTests,",
                         "EpubToMp3Tests/ReaderProgressStoreTests,EpubToMp3Tests/ReaderProgressStoreTests"] {
            XCTAssertThrowsError(try Options(arguments: ["test"], root: root, environment: ["IOS_TESTS": selector]), selector)
        }
    }

    func testSkipBuildCannotBypassCurrentTestBuild() {
        let selection = "EpubToMp3Tests/ReaderProgressStoreTests"
        XCTAssertThrowsError(try Options(arguments: ["test", "--skip-build"], root: root,
                                         environment: ["IOS_TESTS": selection]))
        XCTAssertThrowsError(try Options(arguments: ["test"], root: root,
                                         environment: ["IOS_TESTS": selection, "IOS_SKIP_BUILD": "1"]))
    }

    func testNonTestActionsDoNotRequireOrInterpretTestSelection() throws {
        for action in ["preflight", "status", "benchmark"] {
            let options = try Options(arguments: [action], root: root,
                                      environment: ["IOS_TESTS": "unaudited", "IOS_SKIP_BUILD": "1"])
            XCTAssertEqual(options.testFilters, [])
            XCTAssertEqual(options.expectedTestCount, 0)
            XCTAssertTrue(options.skipBuild)
        }
    }
}
