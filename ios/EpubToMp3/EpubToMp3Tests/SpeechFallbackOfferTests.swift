import XCTest
@testable import EpubToMp3

/// Unit tests for `SpeechFallbackUI.offer(...)` — the pure decision
/// helper the reader uses to surface (or hide) the accessibility-speech
/// affordance. Slice 4 of the SpeechFallback chain.
final class SpeechFallbackOfferTests: XCTestCase {

    // MARK: - Helpers

    private func chapter(
        index: Int,
        downloadUrl: String? = "https://example.com/ch.mp3"
    ) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: index,
            name: "Ch \(index)",
            status: "completed",
            downloadUrl: downloadUrl,
            chars: 1000, charsProcessed: 1000, progressRatio: 1.0,
            durationSeconds: 30, startedAt: 0, completedAt: 0
        )
    }

    private func snapshot(chapters: [JobSnapshot.Chapter]) -> JobSnapshot {
        JobSnapshot(
            jobId: "j", state: "running",
            bookTitle: nil, bookAuthor: nil, coverUrl: nil, coverMimeType: nil,
            engine: nil, voice: nil, language: "en-US",
            progressPercent: nil,
            chaptersTotal: chapters.count, chaptersCompleted: chapters.count,
            chapterProgress: chapters, outputs: nil,
            logUrl: nil, error: nil, lastActivityAt: nil
        )
    }

    private func fulltext(_ chapters: [(index: Int, text: String)]) -> EbookFulltext {
        let items = chapters.map { row in
            EbookFulltext.Chapter(
                index: row.index, name: "Chapter \(row.index)",
                text: row.text, html: nil, css: nil,
                charCount: row.text.count, segments: nil
            )
        }
        return EbookFulltext(
            jobId: "j", bookTitle: "T", bookAuthor: "A",
            chapters: items
        )
    }

    // MARK: - Active state short-circuits

    func test_offer_isActive_whenFallbackAlreadyPlaying() {
        let snap = snapshot(chapters: [chapter(index: 0)])
        let ft = fulltext([(0, "hi")])
        let result = SpeechFallbackUI.offer(
            isFallbackActive: true,
            snapshot: snap, chapterIndex: 0, fulltext: ft, languageCode: "en-US"
        )
        XCTAssertEqual(result, .active)
    }

    func test_offer_isActive_takesPriorityOverMP3Availability() {
        // Even if MP3 would normally be the right choice, an already-
        // playing fallback session must stay in `.active` so the UI
        // shows pause/stop controls, not a "read aloud" CTA.
        let snap = snapshot(chapters: [chapter(index: 0)])
        let result = SpeechFallbackUI.offer(
            isFallbackActive: true,
            snapshot: snap, chapterIndex: 0,
            fulltext: nil, languageCode: nil
        )
        XCTAssertEqual(result, .active)
    }

    // MARK: - Hidden when MP3 is ready

    func test_offer_isHidden_whenChapterMP3IsReady() {
        let snap = snapshot(chapters: [chapter(index: 0)])
        let ft = fulltext([(1, "we have text, but no need to use it")])
        let result = SpeechFallbackUI.offer(
            isFallbackActive: false,
            snapshot: snap, chapterIndex: 0, fulltext: ft, languageCode: "en-US"
        )
        XCTAssertEqual(result, .hidden)
    }

    // MARK: - Available when MP3 missing AND text present

    func test_offer_isAvailable_whenChapterPending_andTextExists() {
        let pending = JobSnapshot.Chapter(
            index: 0, name: "Pending", status: "pending",
            downloadUrl: nil,
            chars: 1000, charsProcessed: 0, progressRatio: 0,
            durationSeconds: nil, startedAt: nil, completedAt: nil
        )
        let snap = snapshot(chapters: [pending])
        XCTAssertTrue(snap.playableChapters.isEmpty,
            "precondition: chapter has no MP3 yet")
        let ft = fulltext([(1, "Plain text we can read aloud.")])

        let result = SpeechFallbackUI.offer(
            isFallbackActive: false,
            snapshot: snap, chapterIndex: 0, fulltext: ft, languageCode: "en-US"
        )
        XCTAssertEqual(result, .available(text: "Plain text we can read aloud.",
                                           languageCode: "en-US"))
    }

    func test_offer_isAvailable_whenSnapshotIsNil_andTextExists() {
        // E.g. instant-reader mode where no conversion job is bound yet.
        let ft = fulltext([(1, "Opening line.")])
        let result = SpeechFallbackUI.offer(
            isFallbackActive: false,
            snapshot: nil, chapterIndex: 0, fulltext: ft, languageCode: "pt-BR"
        )
        XCTAssertEqual(result, .available(text: "Opening line.",
                                           languageCode: "pt-BR"))
    }

    // MARK: - Hidden when MP3 missing AND text missing/empty

    func test_offer_isHidden_whenChapterPending_butNoFulltext() {
        let snap = snapshot(chapters: [])
        let result = SpeechFallbackUI.offer(
            isFallbackActive: false,
            snapshot: snap, chapterIndex: 0, fulltext: nil, languageCode: "en-US"
        )
        XCTAssertEqual(result, .hidden)
    }

    func test_offer_isHidden_whenChapterPending_andTextIsWhitespace() {
        let snap = snapshot(chapters: [])
        let ft = fulltext([(1, "   \n  \t  ")])
        let result = SpeechFallbackUI.offer(
            isFallbackActive: false,
            snapshot: snap, chapterIndex: 0, fulltext: ft, languageCode: "en-US"
        )
        XCTAssertEqual(result, .hidden)
    }

    // MARK: - Chapter index resolution

    func test_offer_resolvesChapter_byBackendOneBasedIndex() {
        // The backend numbers fulltext chapters from 1; snapshot indexes
        // chapters from 0. `offer` must bridge the two transparently.
        let snap = snapshot(chapters: [])
        let ft = fulltext([(1, "first"), (2, "second"), (3, "third")])

        let result = SpeechFallbackUI.offer(
            isFallbackActive: false,
            snapshot: snap, chapterIndex: 1, fulltext: ft, languageCode: nil
        )
        XCTAssertEqual(result, .available(text: "second", languageCode: nil))
    }

    func test_offer_fallsBackToPositionalIndex_whenIndicesDontMatch() {
        // Some payloads have non-contiguous `index` fields (e.g. parts).
        // When the 1-based lookup misses, positional indexing rescues.
        let snap = snapshot(chapters: [])
        let ft = fulltext([(10, "alpha"), (20, "beta"), (30, "gamma")])

        let result = SpeechFallbackUI.offer(
            isFallbackActive: false,
            snapshot: snap, chapterIndex: 1, fulltext: ft, languageCode: "en-US"
        )
        XCTAssertEqual(result, .available(text: "beta", languageCode: "en-US"))
    }

    func test_offer_isHidden_whenChapterIndexOutOfBounds() {
        let snap = snapshot(chapters: [])
        let ft = fulltext([(1, "only")])
        let result = SpeechFallbackUI.offer(
            isFallbackActive: false,
            snapshot: snap, chapterIndex: 99, fulltext: ft, languageCode: "en-US"
        )
        XCTAssertEqual(result, .hidden)
    }

    // MARK: - Language propagation

    func test_offer_propagatesLanguageCode_intoAvailableCase() {
        let snap = snapshot(chapters: [])
        let ft = fulltext([(1, "olá")])
        let result = SpeechFallbackUI.offer(
            isFallbackActive: false,
            snapshot: snap, chapterIndex: 0, fulltext: ft, languageCode: "pt-BR"
        )
        XCTAssertEqual(result, .available(text: "olá", languageCode: "pt-BR"))
    }

    func test_offer_propagatesNilLanguageCode_intoAvailableCase() {
        let snap = snapshot(chapters: [])
        let ft = fulltext([(1, "hola")])
        let result = SpeechFallbackUI.offer(
            isFallbackActive: false,
            snapshot: snap, chapterIndex: 0, fulltext: ft, languageCode: nil
        )
        XCTAssertEqual(result, .available(text: "hola", languageCode: nil))
    }
}
