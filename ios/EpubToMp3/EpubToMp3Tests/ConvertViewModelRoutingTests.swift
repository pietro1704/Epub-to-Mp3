import XCTest

final class ConvertViewModelRoutingTests: XCTestCase {
    func testMobileConversionUsesMultipartUploadInsteadOfSandboxPath() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Conversion/Services/ConvertViewModel.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("uploadedFile: (data: data, filename: file.lastPathComponent)"))
        XCTAssertTrue(source.contains("#if os(macOS)"))
        XCTAssertTrue(source.contains("localPath: file"))
        XCTAssertTrue(source.contains("useEmbeddedRuntime: Bool = false"))
        XCTAssertTrue(source.contains("EmbeddedConversionCoordinator.convert"))
        XCTAssertTrue(source.contains("EmbeddedConversionCoordinator.stream"))
        XCTAssertTrue(source.contains("requiresServerConversion"))
        XCTAssertTrue(source.contains("guard canUseEmbeddedRuntime || client != nil"))
        let screenSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Conversion/Views/ConvertScreenController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(screenSource.contains("preselectedBookID: String? = nil"))
    }
}
