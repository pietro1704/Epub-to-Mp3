import XCTest
@testable import EpubToMp3

final class LibraryConversionStateTests: XCTestCase {
    func testLibraryStoreExposesAConversionStateMutation() throws {
        let source = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Library/Services/LibraryStore.swift")
        )
        XCTAssertTrue(source.contains("func recordConversion(jobId: String, for bookId: String"))
        XCTAssertTrue(source.contains("books[index].lastJobId = jobId"))
    }
}
