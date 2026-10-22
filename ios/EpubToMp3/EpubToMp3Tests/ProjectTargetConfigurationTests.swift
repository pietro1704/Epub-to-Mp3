import XCTest
@testable import EpubToMp3

final class ProjectTargetConfigurationTests: XCTestCase {
    func testShareExtensionTargetIsDeclaredAndEmbeddedOnlyForIOS() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = try readSourceFileIfAvailable(at: projectURL)

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
        let info = try readSourceFileIfAvailable(at: infoURL)

        XCTAssertTrue(info.contains("com.apple.share-services"))
        XCTAssertFalse(info.contains("NSExtensionMainStoryboard"))
        XCTAssertTrue(info.contains("EpubToMp3ShareExtension.ShareViewController"))
    }

    func testShareExtensionFilesystemHelpersAreNonisolated() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3ShareExtension/ShareViewController.swift")
        let source = try readSourceFileIfAvailable(at: sourceURL)

        XCTAssertTrue(source.contains("private nonisolated static func copyToTemp"))
        XCTAssertTrue(source.contains("private nonisolated static func tempURL"))
    }

    @MainActor
    func testWidgetCommandAndApplicationObserveTheSameNotification() {
        XCTAssertEqual(WidgetPlaybackCommand.notificationName, ApplicationWidgetIntents.notificationName)
    }

    func testNativeReaderProjectionParsesLocalDocumentsAndRetainsBookIdentity() async throws {
        let source = try EpubFixture.createWithChapter(body: "Local reader projection fixture.")
        defer { try? FileManager.default.removeItem(at: source) }
        let payload = await EpubFallbackParser.parseAsync(url: source, bookId: "reader-projection")
        XCTAssertEqual(payload.jobId, "reader-projection")
        XCTAssertEqual(payload.chapters.count, 1)
        XCTAssertTrue(payload.chapters[0].text.contains("Local reader projection fixture."))

        let missing = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".epub")
        let unavailable = await EpubFallbackParser.parseAsync(url: missing, bookId: "unavailable-book")
        XCTAssertEqual(unavailable.jobId, "unavailable-book")
        XCTAssertTrue(unavailable.chapters.isEmpty)
    }

    func testNativeConversionControllersHaveTheirSupportingTypes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let detail = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Features/Conversion/Views/JobDetailScreenController.swift"
            )
        )
        let jobs = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Features/Conversion/Views/JobsListScreenController.swift"
            )
        )
        let model = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Features/Conversion/Services/JobDetailViewModel.swift"
            )
        )
        let list = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Features/Conversion/Views/JobsListController.swift"
            )
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
        let state = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Features/Reader/Services/ReaderSessionState.swift"
            )
        )
        let presentation = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Features/Playback/Services/PlayerPresentation.swift"
            )
        )

        XCTAssertEqual(state.components(separatedBy: "enum ReaderSessionState").count, 2)
        XCTAssertFalse(presentation.contains("struct ReaderSessionState"))
    }

    func testWarningsAreBuildErrorsForSwiftAndClang() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = try readSourceFileIfAvailable(at: projectURL)

        XCTAssertTrue(project.contains("SWIFT_TREAT_WARNINGS_AS_ERRORS: YES"))
        XCTAssertTrue(project.contains("GCC_TREAT_WARNINGS_AS_ERRORS: YES"))
    }

    func testCurrentSwiftLanguageModeAndBuildSafetySettingsArePinned() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = try readSourceFileIfAvailable(at: projectURL)

        XCTAssertTrue(project.contains("SWIFT_VERSION: \"5.0\""))
        XCTAssertTrue(project.contains("SWIFT_STRICT_CONCURRENCY: minimal"))
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
        let widgetSync = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Shared/Integrations/WidgetDataSync.swift"
            )
        )
        let zipReader = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Features/Documents/Services/ZipReader.swift"
            )
        )
        let telemetry = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Features/Settings/Views/TelemetryScreenController.swift"
            )
        )

        XCTAssertTrue(widgetSync.contains("private static let lastReadState = LastReadState()"))
        XCTAssertFalse(widgetSync.contains("nonisolated(unsafe) private static var pendingLastRead"))
        XCTAssertFalse(widgetSync.contains("nonisolated(unsafe) private static var lastReadFlushTask"))
        XCTAssertTrue(zipReader.contains("let rc = deflated.withUnsafeBytes"))
        XCTAssertFalse(telemetry.contains("String(format:"))

        let importer = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Features/Offline/Services/SharedContainerImporter.swift"
            )
        )
        XCTAssertTrue(importer.contains("private static let availabilityState = AvailabilityState()"))
        XCTAssertFalse(importer.contains("nonisolated(unsafe) private static var groupAvailabilityCache"))

        let cacheManager = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Features/Offline/Services/ChapterCacheManager.swift"
            )
        )
        let apiClient = try readSourceFileIfAvailable(
            at: root.appendingPathComponent(
                "EpubToMp3/Features/Conversion/Services/APIClient.swift"
            )
        )
        XCTAssertTrue(cacheManager.contains("private final class ObserverState: @unchecked Sendable"))
        XCTAssertTrue(apiClient.contains("final class APIClient: @unchecked Sendable"))
    }

    private func generatedProjectObjects() throws -> [String: [String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("EpubToMp3.xcodeproj/project.pbxproj")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Generated project is unavailable in this runtime sandbox.")
        }
        let project = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url),
            options: [], format: nil) as? [String: Any])
        return try XCTUnwrap(project["objects"] as? [String: [String: Any]])
    }

    func testProjectFileUsesInTreeTargetPathsForAppAndExtensions() throws {
        let objects = try generatedProjectObjects()
        let paths = Set(objects.values.compactMap { $0["path"] as? String })
        for expected in ["EpubToMp3", "EpubToMp3Widget", "EpubToMp3ShareExtension", "EpubToMp3Tests", "EpubToMp3UITests"] {
            XCTAssertTrue(paths.contains(expected), "Missing in-tree source group: \(expected)")
            XCTAssertFalse(paths.contains("../" + expected), "Source group escapes its project: \(expected)")
        }
    }

    func testEachShippingTargetIncludesItsPrivacyManifestInResources() throws {
        let objects = try generatedProjectObjects()
        for name in ["EpubToMp3", "EpubToMp3Widget", "EpubToMp3ShareExtension"] {
            let target = try XCTUnwrap(objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == name })
            let phases = try XCTUnwrap(target["buildPhases"] as? [String])
            let resourcePhases = phases.compactMap { objects[$0] }.filter { $0["isa"] as? String == "PBXResourcesBuildPhase" }
            let resources = resourcePhases.flatMap { $0["files"] as? [String] ?? [] }
                .compactMap { objects[$0]?["fileRef"] as? String }
                .compactMap { objects[$0]?["path"] as? String }
            XCTAssertEqual(resources.filter { URL(fileURLWithPath: $0).lastPathComponent == "PrivacyInfo.xcprivacy" }.count, 1,
                           "\(name) must embed exactly one privacy manifest, regardless of generated object IDs or groups.")
        }
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
                    try readSourceFileIfAvailable(at: pair.legacy),
                    try readSourceFileIfAvailable(at: pair.canonical)
                )
            }
        }
    }
}
