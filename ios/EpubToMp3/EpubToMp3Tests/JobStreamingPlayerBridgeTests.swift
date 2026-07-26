import XCTest

final class JobStreamingPlayerBridgeTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3")
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testJobStreamPublishesSnapshotsToThePlayerBridge() throws {
        let viewModel = try source("Features/Conversion/Services/JobDetailViewModel.swift")
        let controller = try source("Features/Conversion/Views/JobDetailScreenController.swift")
        XCTAssertTrue(viewModel.contains("var onSnapshot: ((JobSnapshot) -> Void)?"))
        XCTAssertTrue(viewModel.contains("self.onSnapshot?(initial)"))
        XCTAssertTrue(viewModel.contains("self.onSnapshot?(next)"))
        XCTAssertTrue(controller.contains("player.updateSnapshot(snapshot)"))
    }
}
