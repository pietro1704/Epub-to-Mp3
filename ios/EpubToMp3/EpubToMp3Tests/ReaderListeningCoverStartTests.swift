import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderListeningCoverStartTests: XCTestCase {
    /// An image-only cover that carries a `<title>` is a reader chapter but has no Rust source text.
    /// Pressing Play on it must narrate the first chapter that has text, not fail the conversion.
    func testListeningFromAnImageOnlyCoverStartsAtTheFirstChapterWithText() async throws {
        let suite = "reader-listening-cover-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let page = { (head: String, body: String) in
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(head)</title></head><body>\(body)</body></html>"
        }
        let source = try EpubFixture.createWithNavigation(documents: [
            (path: "cover.xhtml", html: page("Cover", "<div><img src=\"cover.png\" alt=\"\"/></div>")),
            (path: "one.xhtml", html: page("One", "<h1>One</h1><p>The first synthetic chapter has words.</p>")),
            (path: "two.xhtml", html: page("Two", "<h1>Two</h1><p>The second synthetic chapter has words.</p>"))
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let reader = EpubFallbackParser.parse(url: source, bookId: suite)
        XCTAssertEqual(reader.chapters.count, 3, "The reader shows the cover as its own chapter")

        let book = BookEntity(id: "cover", title: "Cover fixture", bookmark: Data([1]),
                                  displayFilename: "cover.epub", addedAt: Date())
        var starts: [Int32] = []
        var failures: [Error] = []
        let narrated = expectation(description: "The first chapter with text is submitted")
        let session = ReaderListeningSession(
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { url, jobID, start, end, control, options, _, _, _ in
                starts.append(start)
                if start == 1 {
                    narrated.fulfill()
                    throw CancellationError()
                }
                return try await RustConversionCoordinator.executeStreaming(bookURL: url, jobID: jobID,
                    chapterStart: start, chapterEnd: end, control: control, options: options,
                    onProgress: nil, onChapterCompleted: nil, onAudioChunk: nil)
            }, currentBookID: { "cover" }, openBook: { _ in source },
            recordConversion: { _, _ in XCTFail("No audio is produced by this test") },
            reportFailure: { error in
                if !(error is CancellationError) { failures.append(error) }
            }
        )
        defer { session.cancel() }
        session.start(book: book, priority: 0, pageRatio: 0.5,
                      catalog: reader.chapters.map { (index: $0.zeroBasedEpubIndex, title: $0.displayTitle) },
                      conversionOptions: NarrationConversionOptions.current(for: AppSettings(defaults: defaults).ttsPreferences),
                      presentsFullPlayer: false)
        await fulfillment(of: [narrated], timeout: 20)
        XCTAssertEqual(starts, [0, 1])
        XCTAssertTrue(failures.isEmpty, "Starting on the cover is never a conversion failure: \(failures)")
    }
}
