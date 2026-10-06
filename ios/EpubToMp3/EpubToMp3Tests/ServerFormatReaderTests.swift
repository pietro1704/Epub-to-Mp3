import XCTest

final class ServerFormatReaderTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3")
        return try readSourceFileIfAvailable(at: root.appendingPathComponent(relativePath))
    }

    func testIOSReaderUploadsServerOnlyFormatsAndCachesFulltext() throws {
        let source = try source("Features/Reader/Views/BookOpenScreenController.swift")
        XCTAssertTrue(source.contains("book.fileType.requiresServerConversion"))
        XCTAssertTrue(source.contains("client.uploadBook(at: url)"))
        XCTAssertTrue(source.contains("client.fetchUploadedFulltext(uploadID: uploadID)"))
        XCTAssertTrue(source.contains("LocalFulltextCache.save(payload, bookId: book.id)"))
    }

    func testMacReaderUsesTheSameServerFormatContract() throws {
        let source = try source("Features/Reader/Views/MacReaderViewController.swift")
        XCTAssertTrue(source.contains("book.fileType.requiresServerConversion"))
        XCTAssertTrue(source.contains("client.uploadBook(at: fileURL)"))
        XCTAssertTrue(source.contains("client.fetchUploadedFulltext(uploadID: uploadID)"))
    }

    func testAPIClientExposesUploadAndFulltextEndpoints() throws {
        let source = try source("Features/Conversion/Services/APIClient.swift")
        XCTAssertTrue(source.contains("api/uploads"))
        XCTAssertTrue(source.contains("func uploadBook(at fileURL: URL)"))
        XCTAssertTrue(source.contains("func fetchUploadedFulltext(uploadID: String)"))
        XCTAssertTrue(source.contains("fulltext"))
        XCTAssertTrue(source.contains("multipart/form-data"))
        XCTAssertTrue(source.contains("lastPathComponent"))
    }
}
