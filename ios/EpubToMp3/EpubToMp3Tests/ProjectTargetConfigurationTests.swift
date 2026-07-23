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
        XCTAssertTrue(info.contains("EpubToMp3ShareExtension.ShareViewController"))
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
}
