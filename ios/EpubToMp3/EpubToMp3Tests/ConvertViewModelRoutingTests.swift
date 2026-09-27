import XCTest

final class ConvertViewModelRoutingTests: XCTestCase {
    func testMobileConversionUsesMultipartUploadInsteadOfSandboxPath() throws {
        let source = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Conversion/Services/ConvertViewModel.swift")
        )
        XCTAssertTrue(source.contains("uploadedFile: (data: data, filename: file.lastPathComponent)"))
        XCTAssertTrue(source.contains("#if os(macOS)"))
        XCTAssertTrue(source.contains("localPath: file"))
        XCTAssertTrue(source.contains("useEmbeddedRuntime: Bool = false"))
        XCTAssertFalse(source.contains("EmbeddedConversionCoordinator"))
        XCTAssertFalse(source.contains("requiresServerConversion"))
        XCTAssertTrue(source.contains("guard client != nil"))
        let screenSource = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Conversion/Views/ConvertScreenController.swift")
        )
        XCTAssertTrue(screenSource.contains("preselectedBookID: String? = nil"))
    }
}
