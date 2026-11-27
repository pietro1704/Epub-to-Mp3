import XCTest
@testable import EpubToMp3

final class LibraryBookFactsReaderTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUpWithError() throws {
        suite = "LibraryBookFactsReaderTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func book(_ type: BookFileType, jobID: String? = nil) -> BookEntity {
        BookEntity(id: "facts-book", title: "Facts", bookmark: Data([1]), displayFilename: "facts",
                   addedAt: Date(timeIntervalSince1970: 0), lastJobId: jobID, fileType: type)
    }

    private func reader() -> LibraryBookFactsReader {
        var reader = LibraryBookFactsReader()
        reader.defaults = defaults
        reader.artifacts = LocalAudioArtifactStore(root: root)
        reader.convertedSnapshot = { _ in nil }
        reader.chapterCount = { _ in 20 }
        reader.pageCount = { _ in 40 }
        reader.audioSeconds = { _ in 60 }
        return reader
    }

    func testChapterBookReadsSavedPositionAndCorrectedLanguage() async throws {
        ReaderProgressStore.save(bookId: "facts-book", chapterIndex: 6, offsetFraction: 0.4, defaults: defaults)
        BookLanguageSummaries(defaults: defaults).record("en", bookID: "facts-book")
        try BookLanguageCorrections(defaults: defaults).set("pt-BR", bookID: "facts-book")

        let facts = await reader().facts(for: book(.epub))

        XCTAssertEqual(facts.chapterCount, 20)
        XCTAssertNil(facts.pageCount)
        XCTAssertEqual(facts.progress, .init(index: 6, total: 20, fraction: 0.4))
        XCTAssertEqual(facts.languageCode, "pt-BR")
        XCTAssertEqual(facts.audio, .notConverted)
        XCTAssertNil(facts.audioSeconds)
    }

    func testPagedBookReadsTheSavedPage() async throws {
        defaults.set(Data(#"{"page":6,"x":0,"y":0}"#.utf8),
                     forKey: ReaderProgressStore.pdfPositionKey(bookId: "facts-book"))

        let facts = await reader().facts(for: book(.pdf))

        XCTAssertEqual(facts.pageCount, 40)
        XCTAssertNil(facts.chapterCount)
        XCTAssertEqual(facts.progress, .init(index: 6, total: 40, fraction: 1))
    }

    func testUnopenedBookHasNoProgress() async {
        let facts = await reader().facts(for: book(.epub))
        XCTAssertNil(facts.progress)
    }

    func testConvertedAudioCountsAgainstTheConversionTotalAndSumsDurations() async {
        var reader = reader()
        reader.convertedSnapshot = { jobID in
            let chapters = (0..<2).map { index in
                JobSnapshot.Chapter(index: index, name: "c\(index)", status: "completed",
                    downloadUrl: "file:///tmp/c\(index).mp3", chars: nil, charsProcessed: nil,
                    progressRatio: 1, durationSeconds: nil, startedAt: nil, completedAt: nil, textOffset: nil)
            }
            return JobSnapshot(jobId: jobID, state: "finished", bookTitle: "Facts", bookAuthor: nil,
                coverUrl: nil, coverMimeType: nil, engine: "", voice: "", language: nil,
                progressPercent: 100, chaptersTotal: 2, chaptersCompleted: 2, chapterProgress: chapters,
                outputs: nil, logUrl: nil, error: nil, lastActivityAt: 0,
                chapterIndexBase: 0, sourceChaptersTotal: 5)
        }

        let facts = await reader.facts(for: book(.pdf, jobID: "job"))

        XCTAssertEqual(facts.audio, .partial(ready: 2, total: 5))
        XCTAssertEqual(facts.audioSeconds, 120)
    }

    /// The Rust conversion records each chapter as a plain file path, not a URL.
    func testCompleteConversionRecordedAsFilePathsKeepsItsDuration() async {
        var reader = reader()
        reader.audioSeconds = { $0.isFileURL ? 60 : nil }
        reader.convertedSnapshot = { jobID in
            let chapters = (0..<2).map { index in
                JobSnapshot.Chapter(index: index, name: "c\(index)", status: "completed",
                    downloadUrl: "/tmp/Synthetic Book/00\(index) - c.mp3", chars: nil, charsProcessed: nil,
                    progressRatio: 1, durationSeconds: nil, startedAt: nil, completedAt: nil, textOffset: nil)
            }
            return JobSnapshot(jobId: jobID, state: "finished", bookTitle: "Facts", bookAuthor: nil,
                coverUrl: nil, coverMimeType: nil, engine: "", voice: "", language: nil,
                progressPercent: 100, chaptersTotal: 2, chaptersCompleted: 2, chapterProgress: chapters,
                outputs: nil, logUrl: nil, error: nil, lastActivityAt: 0,
                chapterIndexBase: 0, sourceChaptersTotal: 2)
        }

        let facts = await reader.facts(for: book(.epub, jobID: "job"))

        XCTAssertEqual(facts.audio, .complete)
        XCTAssertEqual(facts.audioSeconds, 120)
    }
}
