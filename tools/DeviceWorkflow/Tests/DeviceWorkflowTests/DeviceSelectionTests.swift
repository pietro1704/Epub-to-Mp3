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

    func testTerminalReaderRegressionRequiresOneExactMethod() throws {
        let selector = "EpubToMp3Tests/ReaderProgressiveListeningTests/testTerminalEmptySnapshotDoesNotWaitForReaderPageForever"
        let options = try Options(arguments: ["test"], root: root, environment: ["IOS_TESTS": selector])
        XCTAssertEqual(options.testFilters, [selector])
        XCTAssertEqual(options.expectedTestCount, 1)
    }

    func testAppFixMethodSelectionsPreserveExactOrderAndCount() throws {
        let methods: [(String, [String])] = [
            ("ReaderProgressiveListeningTests", [
                "testMiniPlayerPreservesPageUntilCompleteChapterArrives",
                "testMiniPlayerPageStartKeepsPauseWhileWaitingForChapter",
                "testMiniPlayerRejectsNonfinitePageAnchorAndStreamsImmediately",
                "testMiniPlayerPageAnchorDoesNotSurviveReplacementSession",
                "testRequestedChapterPlaysBeforeConversionFinishesWithoutRestart",
                "testPauseWhileWaitingPreventsChapterAutoplay",
            ]),
            ("AppErrorReporterTests", [
                "testAlertMessageAlsoWritesErrorIdentityAndCauseToTerminal",
                "testStringFailureRetainsLocalizedAlertAndPrefixesEveryDiagnosticLine",
            ]),
            ("RustOutputRootValidationTests", [
                "testSystemTemporaryRootSupportsWritingCountingAndOwnedRemoval",
                "testCustomSymlinkAncestorStillRejectsWritesAndRemoval",
                "testCanonicalRootStillRejectsTraversalAndPreservesAnotherBooksOutput",
            ]),
            ("ToolbarSettingsParityTests", [
                "testInstalledSystemVoiceCanBeSelectedAsSecondaryWithoutChangingPrimary",
                "testNewSpeechSettingsUseFaberWithNativeFallbackAndPersistExplicitNone",
                "testLoadingConsentedEdgeFallbackAdoptsNativeRecoveryWithoutChangingSelections",
                "testExistingSpeechSettingsRetainPrimaryAndRecoverThroughSystem",
                "testExistingExplicitNativeFallbackAdoptsRecoveryWithoutSettingsEdit",
                "testLoadingDuplicateLegacyFallbackClearsOnlySecondary",
            ]),
        ]
        let filters = methods.flatMap { name, tests in tests.map { "EpubToMp3Tests/\(name)/\($0)" } }
        let options = try Options(arguments: ["test"], root: root,
                                  environment: ["IOS_TESTS": filters.joined(separator: ",")])
        XCTAssertEqual(options.testFilters, filters)
        XCTAssertEqual(options.expectedTestCount, 17)
        let reproduction = try Options(arguments: ["test"], root: root,
            environment: ["IOS_TESTS": filters.prefix(2).joined(separator: ",")])
        XCTAssertEqual(reproduction.testFilters, Array(filters.prefix(2)))
        XCTAssertEqual(reproduction.expectedTestCount, 2)
        for filter in filters {
            let single = try Options(arguments: ["test"], root: root, environment: ["IOS_TESTS": filter])
            XCTAssertEqual(single.testFilters, [filter])
            XCTAssertEqual(single.expectedTestCount, 1)
        }
    }

    func testPartialAppFixAuditsNeverAuthorizeWholeClassesOrOtherMethods() {
        for name in ["ReaderProgressiveListeningTests", "AppErrorReporterTests",
                     "RustOutputRootValidationTests", "ToolbarSettingsParityTests"] {
            let selector = "EpubToMp3Tests/\(name)"
            XCTAssertThrowsError(try Options(arguments: ["test"], root: root,
                                             environment: ["IOS_TESTS": selector]), selector)
        }
        for selector in ["EpubToMp3Tests/ToolbarSettingsParityTests/testFontSizeStepperBoundaries",
                         "EpubToMp3Tests/ReaderProgressiveListeningTests/testBookChangedBeforeDeliveryDoesNotAutoplayOldBook",
                         "EpubToMp3Tests/AppErrorReporterTests/test*",
                         "EpubToMp3Tests/RustOutputRootValidationTests/testSystemTemporaryRootSupportsWritingCountingAndOwnedRemoval()"] {
            XCTAssertThrowsError(try Options(arguments: ["test"], root: root,
                                             environment: ["IOS_TESTS": selector]), selector)
        }
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
