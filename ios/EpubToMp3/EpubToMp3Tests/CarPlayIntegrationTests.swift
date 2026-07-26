import XCTest

final class CarPlayIntegrationTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3")
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testCarPlayUsesTheGlobalNowPlayingTemplate() throws {
        let source = try source("Features/Playback/Services/CarPlaySceneDelegate.swift")
        XCTAssertTrue(source.contains("import CarPlay"))
        XCTAssertTrue(source.contains("CPNowPlayingTemplate.shared"))
        XCTAssertTrue(source.contains("CPTabBarTemplate"))
        XCTAssertTrue(source.contains("CPListTemplate"))
        XCTAssertTrue(source.contains("CPTemplateApplicationSceneDelegate"))
    }

    func testApplicationRoutesOnlyCarPlaySessionsToCarPlayDelegate() throws {
        let source = try source("App/EpubToMp3App.swift")
        XCTAssertTrue(source.contains(".carTemplateApplication"))
        XCTAssertTrue(source.contains("CarPlaySceneDelegate.self"))
        XCTAssertTrue(source.contains("isCarPlay ? \"CarPlay\" : \"Default Configuration\""))
    }
}
