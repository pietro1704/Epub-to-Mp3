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

    func testPlaybackFeedbackSelectionIsAuditedAndCountsAllElevenTests() throws {
        let filters = ["EpubToMp3Tests/NativePlaybackFeedbackTests", "EpubToMp3Tests/NativeTransportFeedbackTests"]
        let options = try Options(arguments: ["test"], root: root,
            environment: ["IOS_TESTS": filters.joined(separator: ",")])
        XCTAssertEqual(options.testFilters, filters)
        XCTAssertEqual(options.expectedTestCount, 11)
        XCTAssertThrowsError(try Options(arguments: ["test"], root: root,
            environment: ["IOS_TESTS": "EpubToMp3Tests/NativePlaybackFeedbackTests/testUnaudited"]))
    }

    func testPDFParityAndVoiceRecoveryClassesAreAuditedWithExactCounts() throws {
        let filters = ["PDFReaderParityTests", "TtsMissingVoiceRecoveryTests", "ReaderReadingPositionTests",
                       "ReaderAccessibilityContractTests", "SpeechModelObserverLifetimeTests"].map { "EpubToMp3Tests/\($0)" }
        let options = try Options(arguments: ["test"], root: root,
            environment: ["IOS_TESTS": filters.joined(separator: ",")])
        XCTAssertEqual(options.testFilters, filters)
        XCTAssertEqual(options.expectedTestCount, 24)
        XCTAssertThrowsError(try Options(arguments: ["test"], root: root,
            environment: ["IOS_TESTS": "EpubToMp3Tests/PDFReaderParityTests/testUnaudited"]))
    }

    func testModelsScreenAlertRegressionIsAuditedWithItsFourCases() throws {
        let options = try Options(arguments: ["test"], root: root,
            environment: ["IOS_TESTS": "EpubToMp3Tests/ModelsScreenAlertTests"])
        XCTAssertEqual(options.testFilters, ["EpubToMp3Tests/ModelsScreenAlertTests"])
        XCTAssertEqual(options.expectedTestCount, 4)
    }

    func testSkipBackRegressionsAreAuditedAsExactMethods() throws {
        let prefix = "EpubToMp3Tests/AudioPlayerPendingSeekTests/"
        let names = ["testSkipBackwardBeforeTheGeneratedOriginRestartsFromTheEstimatedTextPosition",
                     "testRepeatedBackwardSkipsInsideTheRetainedAudioAccumulate",
                     "testBackwardSkipNearTheChapterStartLandsAtTheStartWithoutLoadingForever"].map { prefix + $0 }
        let options = try Options(arguments: ["test"], root: root, environment: ["IOS_TESTS": names.joined(separator: ",")])
        XCTAssertEqual(options.testFilters, names)
        XCTAssertEqual(options.expectedTestCount, 3)
    }

    func testModelSwitchRegressionIsAuditedAsOneExactMethod() throws {
        let selector = "EpubToMp3Tests/ReaderListeningSessionTests/testSwitchingTheModelWhileListeningRetiresTheOldJobSilentlyAndKeepsPlaying"
        let options = try Options(arguments: ["test"], root: root, environment: ["IOS_TESTS": selector])
        XCTAssertEqual(options.testFilters, [selector])
        XCTAssertEqual(options.expectedTestCount, 1)
        XCTAssertThrowsError(try Options(arguments: ["test"], root: root,
            environment: ["IOS_TESTS": "EpubToMp3Tests/ReaderListeningSessionTests"]))
    }

    func testAuditedClassesComeFromOneFilePerClassUnderTheRepositoryRoot() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("audited-\(UUID().uuidString)")
        let directory = scratch.appendingPathComponent("tools/DeviceWorkflow/Audited")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try "# comment\ntestOne\ntestTwo\n".write(to: directory.appendingPathComponent("FreshTests.txt"), atomically: true, encoding: .utf8)
        try "* whole class\ntestA\ntestB\n".write(to: directory.appendingPathComponent("WholeTests.txt"), atomically: true, encoding: .utf8)
        func filters(_ value: String) throws -> Options {
            try Options(arguments: ["test"], root: scratch, environment: ["IOS_TESTS": value])
        }
        XCTAssertEqual(try filters("EpubToMp3Tests/FreshTests/testOne").expectedTestCount, 1)
        XCTAssertThrowsError(try filters("EpubToMp3Tests/FreshTests/testMissing"))
        XCTAssertThrowsError(try filters("EpubToMp3Tests/FreshTests"), "A partially audited class needs exact methods")
        XCTAssertEqual(try filters("EpubToMp3Tests/WholeTests").expectedTestCount, 2)
        XCTAssertThrowsError(try filters("EpubToMp3Tests/Unaudited/testX"))
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

    func testBackgroundLockUITestAdmitsOnlyItsExactMethodInTheUITestTarget() throws {
        let method = "testPlaybackContinuesAtHomeAndLockedAcrossChapterBoundary"
        let selector = "EpubToMp3UITests/BackgroundLockPlaybackDeviceUITests/\(method)"
        let options = try Options(arguments: ["test"], root: root, environment: ["IOS_TESTS": selector])
        XCTAssertEqual(options.testFilters, [selector])
        XCTAssertEqual(options.expectedTestCount, 1)
        for rejected in ["EpubToMp3UITests/BackgroundLockPlaybackDeviceUITests",
                         "EpubToMp3Tests/BackgroundLockPlaybackDeviceUITests/\(method)",
                         "EpubToMp3UITests/BackgroundLockPlaybackDeviceUITests/testUnaudited",
                         "EpubToMp3UITests/ReaderViewportTransitionTests/testCancelInvalidatesOutstandingToken"] {
            XCTAssertThrowsError(try Options(arguments: ["test"], root: root,
                                             environment: ["IOS_TESTS": rejected]), rejected)
        }
    }

    func testRetainedAudioAuditAdmitsOnlyTheIsolatedFixtureMethods() throws {
        let filters = [
            "EpubToMp3Tests/DownloadedAudioFilesMirrorTests/testRedownloadKeepsAFileTheListenerEditedAtTheOriginalPath",
            "EpubToMp3Tests/LegacyAudioMigrationCoordinatorTests/testFailedVisibleCopyKeepsTheLegacyFileUntilMigrationCanRetry",
            "EpubToMp3Tests/DownloadManagerBackgroundTests/testDownloadWithoutAKnownBookKeepsTheJobAndChapterIndices",
        ]
        let options = try Options(arguments: ["test"], root: root,
                                  environment: ["IOS_TESTS": filters.joined(separator: ",")])
        XCTAssertEqual(options.testFilters, filters)
        XCTAssertEqual(options.expectedTestCount, 3)
        for selector in filters {
            let suite = selector.split(separator: "/").prefix(2).joined(separator: "/")
            XCTAssertThrowsError(try Options(arguments: ["test"], root: root,
                                             environment: ["IOS_TESTS": suite]))
            XCTAssertThrowsError(try Options(arguments: ["test"], root: root,
                                             environment: ["IOS_TESTS": "\(suite)/testUnaudited"]))
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
