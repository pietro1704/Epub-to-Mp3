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

final class BookFileTypeTests: XCTestCase {
    private func detect(_ filename: String) -> BookFileType {
        BookFileType.detect(from: URL(fileURLWithPath: "/tmp/\(filename)"))
    }

    func testDetectsEachSupportedExtension() {
        XCTAssertEqual(detect("book.epub"), .epub)
        XCTAssertEqual(detect("book.pdf"), .pdf)
        XCTAssertEqual(detect("book.fb2"), .fb2)
        XCTAssertEqual(detect("book.docx"), .docx)
        XCTAssertEqual(detect("book.cbz"), .cbz)
        XCTAssertEqual(detect("book.cbr"), .cbr)
        XCTAssertEqual(detect("book.mobi"), .mobi)
        XCTAssertEqual(detect("book.azw3"), .azw3)
        XCTAssertEqual(detect("book.azw"), .azw3)
    }

    func testDetectionIsCaseInsensitive() {
        XCTAssertEqual(detect("book.EPUB"), .epub)
        XCTAssertEqual(detect("book.CBZ"), .cbz)
    }

    func testUnknownExtensionIsExplicitlyUnsupportedNotSilentlyEpub() {
        XCTAssertEqual(detect("book.txt"), .unsupported)
        XCTAssertEqual(detect("book"), .unsupported)
    }

    func testOnlyComicsAreExcludedFromAudioConversion() {
        for type in BookFileType.allCases {
            let expected = (type != .cbz && type != .cbr && type != .unsupported)
            XCTAssertEqual(
                type.supportsAudioConversion, expected,
                "\(type) supportsAudioConversion mismatch"
            )
        }
    }

    func testOnlyMobiAzw3AndCbrRequireServerConversion() {
        for type in BookFileType.allCases {
            let expected = (type == .mobi || type == .azw3 || type == .cbr)
            XCTAssertEqual(
                type.requiresServerConversion, expected,
                "\(type) requiresServerConversion mismatch"
            )
        }
    }
}
