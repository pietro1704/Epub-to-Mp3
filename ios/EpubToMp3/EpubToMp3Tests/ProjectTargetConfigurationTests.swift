import XCTest

final class ProjectTargetConfigurationTests: XCTestCase {
    func testShareExtensionTargetIsDeclaredAndEmbeddedOnlyForIOS() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("EpubToMp3ShareExtension:"))
        XCTAssertTrue(project.contains("type: app-extension"))
        XCTAssertTrue(project.contains("INFOPLIST_FILE: EpubToMp3ShareExtension/Info.plist"))
        XCTAssertTrue(project.contains("CODE_SIGN_ENTITLEMENTS: EpubToMp3ShareExtension/ShareExtension.entitlements"))
        XCTAssertTrue(project.contains("EpubToMp3/Shared/Integrations/SharedContainerInbox.swift"))
        XCTAssertTrue(project.contains("- target: EpubToMp3ShareExtension\n        embed: true"))
        XCTAssertTrue(project.contains("EpubToMp3ShareExtension.appex"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectURL.deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3ShareExtension/ShareViewController.swift").path
        ))
    }

    func testShareExtensionInfoDeclaresShareServicesPrincipalClass() throws {
        let infoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3ShareExtension/Info.plist")
        let info = try String(contentsOf: infoURL, encoding: .utf8)

        XCTAssertTrue(info.contains("com.apple.share-services"))
        XCTAssertFalse(info.contains("NSExtensionMainStoryboard"))
        XCTAssertTrue(info.contains("EpubToMp3ShareExtension.ShareViewController"))
    }

    func testShareExtensionFilesystemHelpersAreNonisolated() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3ShareExtension/ShareViewController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private nonisolated static func copyToTemp"))
        XCTAssertTrue(source.contains("private nonisolated static func tempURL"))
    }

    func testWidgetDarwinNotificationKeepsSendableStorage() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3Widget/EpubToMp3Widget.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private let widgetIntentDarwinNotification = \""))
        XCTAssertFalse(source.contains("= \"com.pietrocode.epubtomp3.widgetIntent\" as CFString"))
    }

    func testNativeBookReaderUsesPythonParserWithoutSwiftFallback() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Features/Reader/Views/BookOpenScreenController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("PythonBridge.shared.parseEpub"))
        XCTAssertFalse(source.contains("EpubFallbackParser.parse"))
    }

    func testNativeConversionControllersHaveTheirSupportingTypes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let detail = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Conversion/Views/JobDetailScreenController.swift"
            ), encoding: .utf8
        )
        let jobs = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Conversion/Views/JobsListScreenController.swift"
            ), encoding: .utf8
        )
        let model = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Conversion/Services/JobDetailViewModel.swift"
            ), encoding: .utf8
        )
        let list = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Conversion/Views/JobsListController.swift"
            ), encoding: .utf8
        )

        XCTAssertTrue(detail.contains("JobDetailViewModel()"))
        XCTAssertTrue(model.contains("final class JobDetailViewModel"))
        XCTAssertTrue(jobs.contains("JobsListController()"))
        XCTAssertTrue(list.contains("final class JobsListController"))
    }

    func testReaderSessionStateHasOneNativeDefinition() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let state = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Reader/Services/ReaderSessionState.swift"
            ), encoding: .utf8
        )
        let presentation = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Playback/Services/PlayerPresentation.swift"
            ), encoding: .utf8
        )

        XCTAssertEqual(state.components(separatedBy: "enum ReaderSessionState").count, 2)
        XCTAssertFalse(presentation.contains("struct ReaderSessionState"))
    }

    func testWarningsAreBuildErrorsForSwiftAndClang() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("SWIFT_TREAT_WARNINGS_AS_ERRORS: YES"))
        XCTAssertTrue(project.contains("GCC_TREAT_WARNINGS_AS_ERRORS: YES"))
    }

    func testSwift6MigrationAndBuildSafetySettingsArePinned() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("SWIFT_VERSION: \"6\""))
        XCTAssertTrue(project.contains("SWIFT_STRICT_CONCURRENCY: complete"))
        XCTAssertTrue(project.contains("SWIFT_STRICT_MEMORY_SAFETY: YES"))
        XCTAssertTrue(project.contains("SWIFT_STRICT_MEMORY_SAFETY: NO"))
        XCTAssertTrue(project.contains("SWIFT_ENFORCE_EXCLUSIVE_ACCESS: full"))
        XCTAssertTrue(project.contains("SWIFT_COMPILATION_MODE: incremental"))
        XCTAssertTrue(project.contains("SWIFT_COMPILATION_MODE: wholemodule"))
        XCTAssertTrue(project.contains("ONLY_ACTIVE_ARCH: YES"))
        XCTAssertTrue(project.contains("ONLY_ACTIVE_ARCH: NO"))
        XCTAssertTrue(project.contains("LLVM_LTO: YES_THIN"))
    }

    func testStrictMemorySafetyUsesExplicitBoundaries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widgetSync = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Shared/Integrations/WidgetDataSync.swift"
            ), encoding: .utf8
        )
        let zipReader = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Documents/Services/ZipReader.swift"
            ), encoding: .utf8
        )
        let telemetry = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Settings/Views/TelemetryScreenController.swift"
            ), encoding: .utf8
        )

        XCTAssertTrue(widgetSync.contains("private static let lastReadState = LastReadState()"))
        XCTAssertFalse(widgetSync.contains("nonisolated(unsafe) private static var pendingLastRead"))
        XCTAssertFalse(widgetSync.contains("nonisolated(unsafe) private static var lastReadFlushTask"))
        XCTAssertTrue(zipReader.contains("let rc = unsafe deflated.withUnsafeBytes"))
        XCTAssertFalse(telemetry.contains("String(format:"))

        let pythonRunner = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Conversion/Services/PythonRunner.swift"
            ), encoding: .utf8
        )
        let importer = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Offline/Services/SharedContainerImporter.swift"
            ), encoding: .utf8
        )
        XCTAssertTrue(pythonRunner.contains("private final class CompletionGate: @unchecked Sendable"))
        XCTAssertTrue(importer.contains("private static let availabilityState = AvailabilityState()"))
        XCTAssertFalse(importer.contains("nonisolated(unsafe) private static var groupAvailabilityCache"))

        let cacheManager = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Offline/Services/ChapterCacheManager.swift"
            ), encoding: .utf8
        )
        let apiClient = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Conversion/Services/APIClient.swift"
            ), encoding: .utf8
        )
        XCTAssertTrue(cacheManager.contains("private final class ObserverState: @unchecked Sendable"))
        XCTAssertTrue(apiClient.contains("final class APIClient: @unchecked Sendable"))
    }

    func testProjectFileUsesInTreeTargetPathsForAppAndExtensions() throws {
        let projectFileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3.xcodeproj/project.pbxproj")
        let projectFile = try String(contentsOf: projectFileURL, encoding: .utf8)

        XCTAssertTrue(projectFile.contains("path = EpubToMp3;"))
        XCTAssertTrue(projectFile.contains("path = Vendor;"))
        XCTAssertTrue(projectFile.contains("path = EpubToMp3Widget;"))
        XCTAssertTrue(projectFile.contains("path = EpubToMp3ShareExtension;"))
        XCTAssertTrue(projectFile.contains("path = EpubToMp3Tests;"))
        XCTAssertTrue(projectFile.contains("path = EpubToMp3UITests;"))
        XCTAssertFalse(projectFile.contains("path = ../EpubToMp3;"))
        XCTAssertFalse(projectFile.contains("path = ../Vendor;"))
        XCTAssertFalse(projectFile.contains("path = ../EpubToMp3Widget;"))
        XCTAssertFalse(projectFile.contains("path = ../EpubToMp3ShareExtension;"))
        XCTAssertFalse(projectFile.contains("path = ../EpubToMp3Tests;"))
        XCTAssertFalse(projectFile.contains("path = ../EpubToMp3UITests;"))
    }

    func testProjectFileUsesExplicitPrivacyManifestPaths() throws {
        let projectFileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3.xcodeproj/project.pbxproj")
        let projectFile = try String(contentsOf: projectFileURL, encoding: .utf8)

        XCTAssertEqual(projectFile.components(separatedBy: "PrivacyInfo.xcprivacy").count - 1, 18)
        XCTAssertTrue(projectFile.contains("PrivacyInfo.xcprivacy in Resources"))
    }

    func testLegacyTopLevelPrivacyManifestsExistAndMatchCanonicalCopies() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestPairs = [
            (
                canonical: repoRoot.appendingPathComponent("ios/EpubToMp3/EpubToMp3Widget/PrivacyInfo.xcprivacy"),
                legacy: repoRoot.appendingPathComponent("ios/EpubToMp3Widget/PrivacyInfo.xcprivacy")
            ),
            (
                canonical: repoRoot.appendingPathComponent("ios/EpubToMp3/EpubToMp3ShareExtension/PrivacyInfo.xcprivacy"),
                legacy: repoRoot.appendingPathComponent("ios/EpubToMp3ShareExtension/PrivacyInfo.xcprivacy")
            ),
        ]

        for pair in manifestPairs {
            guard FileManager.default.fileExists(atPath: pair.canonical.path) else { continue }
            if FileManager.default.fileExists(atPath: pair.legacy.path) {
                XCTAssertEqual(
                    try String(contentsOf: pair.legacy, encoding: .utf8),
                    try String(contentsOf: pair.canonical, encoding: .utf8)
                )
            }
        }
    }
}
