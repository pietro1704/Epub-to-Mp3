import XCTest
@testable import EpubToMp3

final class ConvertViewModelTests: XCTestCase {
    @MainActor
    func testMissingClientAndFileProduceActionableErrors() async {
        let model = ConvertViewModel()

        await model.submit(client: nil)
        XCTAssertEqual(model.error, L10n.string("convert.error.pickFileFirst"))

        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:1")!)
        model.error = nil
        await model.submit(client: client)
        XCTAssertEqual(model.error, L10n.string("convert.error.pickFileFirst"))
    }

#if os(macOS)
    @MainActor
    func testImportForConversionCopiesIntoOwnedInbox() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("convert-(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Book.epub")
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try Data("epub".utf8).write(to: source)

        let copied = try ConvertViewModel.importForConversion(source, baseDirectory: inbox)

        XCTAssertNotEqual(copied.standardizedFileURL, source.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: copied), Data("epub".utf8))
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
    }
#endif
}
