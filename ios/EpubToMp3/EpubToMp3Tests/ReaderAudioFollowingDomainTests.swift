import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderAudioFollowingDomainTests: XCTestCase {
    private let spans = [
        SentenceSpan(id: "s1", text: "First sentence.", startChar: 0, endChar: 15),
        SentenceSpan(id: "s2", text: "Second sentence.", startChar: 16, endChar: 32),
        SentenceSpan(id: "s3", text: "Third sentence.", startChar: 34, endChar: 49)
    ]

    func testAnchorCanRepresentSharedReaderAndAudioPosition() {
        let anchor = ReaderAudioPositionAnchor(chapterIndex: 2, sentenceID: "s2", pageRatio: 0.4, scrollOffset: 120)
        XCTAssertEqual(anchor.chapterIndex, 2)
        XCTAssertEqual(anchor.sentenceID, "s2")
        XCTAssertTrue(anchor.isMeaningful)
    }

    func testManualMoveDivergesForExactlyFiveSecondsThenAudioWins() {
        var state = ManualDivergenceStateMachine(cooldown: 5)
        let start = Date(timeIntervalSince1970: 100)
        state.manualMove(at: start)
        XCTAssertTrue(state.isDivergent(at: start.addingTimeInterval(4.999)))
        XCTAssertFalse(state.isDivergent(at: start.addingTimeInterval(5)))
        XCTAssertTrue(state.shouldFollowAudio(at: start.addingTimeInterval(5)))
    }

    func testAudioFollowResolvesSentenceToPaginatedPage() {
        let pages = [
            NSAttributedString(string: String(repeating: "a", count: 20)),
            NSAttributedString(string: String(repeating: "b", count: 20))
        ]
        XCTAssertEqual(
            ReaderAudioFollowResolver.pageIndex(
                for: spans[2], pages: pages
            ),
            1
        )
    }

    func testExplicitFollowEndsDivergenceImmediately() {
        var state = ManualDivergenceStateMachine()
        state.manualMove(at: Date(timeIntervalSince1970: 10))
        state.followAudio()
        XCTAssertFalse(state.isDivergent(at: Date(timeIntervalSince1970: 10.1)))
    }

    func testContinuationOffersChoicesOnlyWhenBothPositionsAreMeaningful() {
        let reader = ReaderAudioPositionAnchor(chapterIndex: 1, sentenceID: "reader", pageRatio: nil, scrollOffset: nil)
        let audio = ReaderAudioPositionAnchor(chapterIndex: 3, sentenceID: "audio", pageRatio: nil, scrollOffset: nil)
        XCTAssertEqual(ContinuationChoiceResolver.resolve(reader: reader, audio: audio), .offer([.reader, .audio]))
        XCTAssertEqual(ContinuationChoiceResolver.resolve(reader: reader, audio: nil), .start(.reader(reader)))
        XCTAssertEqual(ContinuationChoiceResolver.resolve(reader: nil, audio: audio), .start(.audio(audio)))
        XCTAssertEqual(ContinuationChoiceResolver.resolve(reader: nil, audio: nil), .startDefault)
    }

    func testPhraseAndParagraphTargetsResolveFromSelection() {
        let paragraphs = [TextParagraph(id: "p1", startChar: 0, endChar: 32), TextParagraph(id: "p2", startChar: 34, endChar: 49)]
        XCTAssertEqual(PlaybackTargetResolver.phraseTarget(for: NSRange(location: 18, length: 3), spans: spans), .sentence(spans[1]))
        XCTAssertEqual(PlaybackTargetResolver.paragraphTarget(for: NSRange(location: 18, length: 3), spans: spans, paragraphs: paragraphs), .sentence(spans[0]))
        XCTAssertNil(PlaybackTargetResolver.phraseTarget(for: NSRange(location: 100, length: 1), spans: spans))
    }

    func testWordTimingUsesRealTimingBeforeProportionalFallback() {
        let sentence = spans[1]
        let real = [WordTiming(word: "Second", start: 0.2, end: 0.6)]
        XCTAssertEqual(WordTimingResolver.activeWord(in: sentence, elapsed: 0.3, sentenceDuration: 2, realTiming: real)?.word, "Second")
        let estimated = WordTimingResolver.estimate(in: sentence, sentenceDuration: 2)
        XCTAssertEqual(estimated.count, 2)
        XCTAssertEqual(estimated.first?.word, "Second")
        XCTAssertEqual(WordTimingResolver.activeWord(in: sentence, elapsed: 1.8, sentenceDuration: 2, realTiming: nil)?.word, "sentence.")
    }

    func testPlayerReaderNavigationSynchronizesReaderCoordinatorChapter() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/PlayerReaderView.swift"),
            encoding: .utf8
        )
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "readerCoordinator.setChapter(").count - 1, 3)
    }

    func testReaderCoordinatorPositionIsNamespacedByBook() {
        let defaults = UserDefaults(suiteName: "ReaderPositionTests.\(UUID().uuidString)")!
        let coordinator = ReaderCoordinator(defaults: defaults)
        _ = coordinator.load(for: "book-a", fallbackChapterIndex: 0)
        coordinator.setChapter(3)
        coordinator.setPagePosition(ratio: 0.625, sentenceId: "a-sentence")
        coordinator.flush()

        let other = ReaderCoordinator(defaults: defaults)
        let otherAnchor = other.load(for: "book-b", fallbackChapterIndex: 1)
        XCTAssertEqual(otherAnchor.chapterIndex, 1)
        XCTAssertNil(otherAnchor.pageRatio)

        let restored = other.load(for: "book-a", fallbackChapterIndex: 0)
        XCTAssertEqual(restored.chapterIndex, 3)
        XCTAssertEqual(restored.pageRatio ?? -1, 0.625, accuracy: 0.001)
        XCTAssertEqual(restored.sentenceId, "a-sentence")
    }

    func testResumeStorePersistsPlayingStateAndPosition() {
        let defaults = UserDefaults(suiteName: "ResumeStoreTests.\(UUID().uuidString)")!
        let store = ResumeStore(storage: defaults)
        store.save(jobId: "book-a", chapterIndex: 2, position: 105, wasPlaying: true)
        let marker = store.marker(jobId: "book-a", chapterIndex: 2)
        XCTAssertEqual(marker?.positionSeconds, 105)
        XCTAssertTrue(marker?.wasPlaying == true)
    }

    func testReaderCoordinatorChapterChangeClearsSentenceAnchor() {
        let defaults = UserDefaults(suiteName: "ReaderAudioFollowingDomainTests.\(UUID().uuidString)")!
        defaults.set("old", forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey)
        let coordinator = ReaderCoordinator(defaults: defaults)
        coordinator.setChapter(4)
        XCTAssertEqual(coordinator.anchor.chapterIndex, 4)
        XCTAssertNil(coordinator.anchor.sentenceId)
    }
}
