import XCTest
@testable import EpubToMp3

final class BookEntityTests: XCTestCase {

    private func make(
        cachedOffline: Bool = false,
        lastJobId: String? = nil,
        title: String = "Foundation"
    ) -> BookEntity {
        BookEntity(
            id: "abc",
            title: title,
            author: "Asimov",
            bookmark: Data(),
            displayFilename: "foundation.epub",
            addedAt: Date(),
            lastOpenedAt: nil,
            lastChapterIndex: nil,
            lastPositionSeconds: nil,
            coverPNG: nil,
            lastJobId: lastJobId,
            cachedOffline: cachedOffline
        )
    }

    func testStatusOfflineReadyOverridesEverything() {
        let book = make(cachedOffline: true, lastJobId: "job-1")
        XCTAssertEqual(book.status, .offlineReady)
    }

    func testStatusCachingWhenLastJobIdPresentButNotOffline() {
        let book = make(cachedOffline: false, lastJobId: "job-1")
        XCTAssertEqual(book.status, .caching)
    }

    func testStatusTextOnlyWhenNoJob() {
        XCTAssertEqual(make().status, .textOnly)
    }

    func testResolvedTitleFallsBackToFilenameWhenTitleIsBlank() {
        let book = make(title: "  ")
        XCTAssertEqual(book.resolvedTitle, "foundation.epub")
    }

    func testCodableRoundTrip() throws {
        let original = make(cachedOffline: true, lastJobId: "j-99")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BookEntity.self, from: encoded)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.lastJobId, original.lastJobId)
        XCTAssertEqual(decoded.cachedOffline, original.cachedOffline)
        XCTAssertEqual(decoded.status, .offlineReady)
    }
}
