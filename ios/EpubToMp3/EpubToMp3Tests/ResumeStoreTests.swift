import XCTest
@testable import EpubToMp3

private final class InMemoryStorage: ResumeStorage {
    var blob: Data?
    func data(forKey key: String) -> Data? { blob }
    func set(_ value: Data?, forKey key: String) { blob = value }
}

final class ResumeStoreTests: XCTestCase {

    func testSaveAndReadRoundtrip() {
        let storage = InMemoryStorage()
        let store = ResumeStore(storage: storage)
        store.save(jobId: "job-a", chapterIndex: 2, position: 145.5)

        let store2 = ResumeStore(storage: storage)
        let marker = store2.marker(jobId: "job-a", chapterIndex: 2)
        XCTAssertEqual(marker?.positionSeconds, 145.5)
        XCTAssertEqual(marker?.chapterIndex, 2)
        XCTAssertEqual(marker?.jobId, "job-a")
    }

    func testClearJobOnlyEvictsMatchingJob() {
        let storage = InMemoryStorage()
        let store = ResumeStore(storage: storage)
        store.save(jobId: "a", chapterIndex: 0, position: 10)
        store.save(jobId: "b", chapterIndex: 0, position: 20)
        store.clear(jobId: "a")
        XCTAssertNil(store.marker(jobId: "a", chapterIndex: 0))
        XCTAssertEqual(store.marker(jobId: "b", chapterIndex: 0)?.positionSeconds, 20)
    }

    func testNegativePositionsAreClampedToZero() {
        let storage = InMemoryStorage()
        let store = ResumeStore(storage: storage)
        store.save(jobId: "j", chapterIndex: 0, position: -42)
        XCTAssertEqual(store.marker(jobId: "j", chapterIndex: 0)?.positionSeconds, 0)
    }

    func testKeyFormat() {
        XCTAssertEqual(ResumeStore.key(jobId: "abc", chapterIndex: 7), "abc#7")
    }
}

final class DownloadManagerHelperTests: XCTestCase {
    func testSanitizedFileNameStripsInvalidChars() {
        let cleaned = DownloadManager.sanitizedFileName("Chapter 1: Hello/World?")
        XCTAssertFalse(cleaned.contains("/"))
        XCTAssertFalse(cleaned.contains("?"))
        XCTAssertFalse(cleaned.contains(":"))
    }

    func testSanitizedFileNameFallsBackToChapterOnEmpty() {
        XCTAssertEqual(DownloadManager.sanitizedFileName("   "), "chapter")
    }

    func testResolveAbsoluteURL() {
        let url = DownloadManager.resolve(path: "https://x.example/a.mp3", base: nil)
        XCTAssertEqual(url?.absoluteString, "https://x.example/a.mp3")
    }

    func testResolveRelativeAgainstBase() {
        let base = URL(string: "http://localhost:8000")!
        let url = DownloadManager.resolve(path: "/api/outputs/j/x.mp3", base: base)
        XCTAssertEqual(url?.absoluteString, "http://localhost:8000/api/outputs/j/x.mp3")
    }
}
