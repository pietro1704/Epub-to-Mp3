import XCTest
@testable import EpubToMp3

final class EbookFulltextTests: XCTestCase {

    func testDecodesBackendPayload() throws {
        let json = """
        {
          "jobId": "abc-123",
          "bookTitle": "Foundation",
          "bookAuthor": "Asimov",
          "chapters": [
            {"index": 1, "name": "Prologue", "text": "Hello world. Second sentence!",
             "html": "<p>Hello world.</p>", "css": "", "charCount": 29}
          ]
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(EbookFulltext.self, from: json)
        XCTAssertEqual(payload.jobId, "abc-123")
        XCTAssertEqual(payload.chapters.count, 1)
        XCTAssertEqual(payload.chapters.first?.displayTitle, "Prologue")
        XCTAssertEqual(payload.chapters.first?.charCount, 29)
        XCTAssertNil(payload.chapters.first?.segments)
    }

    func testDecodesOptionalSegmentsWhenPresent() throws {
        // Forward-compatible: backend doesn't ship `segments` today, but
        // when it does, decoding must Just Work.
        let json = """
        {
          "jobId": "j",
          "chapters": [
            {"index": 1, "name": "Ch", "text": "abc",
             "segments": [
               {"id": "1:0", "text": "abc", "startMs": 0, "endMs": 1500}
             ]}
          ]
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(EbookFulltext.self, from: json)
        XCTAssertEqual(payload.chapters.first?.segments?.count, 1)
        XCTAssertEqual(payload.chapters.first?.segments?.first?.startMs, 1500 - 1500)
        XCTAssertEqual(payload.chapters.first?.segments?.first?.endMs, 1500)
    }

    func testIgnoresUnknownFields() throws {
        let json = """
        {"jobId": "j", "chapters": [], "futureField": 42}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(EbookFulltext.self, from: json)
        XCTAssertEqual(payload.jobId, "j")
        XCTAssertEqual(payload.chapters.count, 0)
    }

    func testSplitSentencesOnPunctuation() {
        let chapter = EbookFulltext.Chapter(
            index: 1,
            name: "Ch",
            text: "First sentence. Second one! Third? Final no punct",
            html: nil, css: nil, charCount: nil, segments: nil
        )
        let spans = chapter.splitSentences()
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans[0].text, "First sentence.")
        XCTAssertEqual(spans[1].text, "Second one!")
        XCTAssertEqual(spans[2].text, "Third?")
        XCTAssertEqual(spans[3].text, "Final no punct")
        XCTAssertEqual(spans[0].id, "1:0")
        XCTAssertEqual(spans[3].id, "1:3")
    }

    func testSplitSentencesHandlesEmptyText() {
        let chapter = EbookFulltext.Chapter(
            index: 0, name: "", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertTrue(chapter.splitSentences().isEmpty)
    }

    // MARK: - cleanTitle / displayTitle

    func testCleanTitleSeparatesGluedRomanNumeral() {
        // "parteI" → regex inserts space → "parte I"
        // Not all-lowercase (contains uppercase I) so no .capitalized applied.
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "parteI", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "parte I")
    }

    func testCleanTitleSeparatesGluedDigit() {
        let chapter = EbookFulltext.Chapter(
            index: 3, name: "Chapter3", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "Chapter 3")
    }

    func testCleanTitlePreservesAllUppercase() {
        // All-uppercase like "PROLOGUE" should NOT be lowercased — it stays
        // as-is because the condition `result == result.lowercased()` is false.
        let chapter = EbookFulltext.Chapter(
            index: 0, name: "PROLOGUE", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "PROLOGUE")
    }

    func testCleanTitleCapitalizesAllLowercase() {
        let chapter = EbookFulltext.Chapter(
            index: 2, name: "os primeiros", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "Os Primeiros")
    }

    func testCleanTitleLeavesAlreadyCleanUnchanged() {
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "Chapter 1", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "Chapter 1")
    }

    func testCleanTitleTrimsWhitespace() {
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "  Intro  ", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "Intro")
    }

    func testDisplayTitleFallbackWhenNameIsNil() {
        let chapter = EbookFulltext.Chapter(
            index: 5, name: nil, text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        // Must delegate to L10n (locale-aware), never a hardcoded literal —
        // on a pt-BR device the fallback reads "Capítulo 5".
        XCTAssertEqual(chapter.displayTitle, L10n.string("player.chapter", 5))
    }

    func testDisplayTitleFallbackWhenNameIsEmpty() {
        let chapter = EbookFulltext.Chapter(
            index: 7, name: "", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, L10n.string("player.chapter", 7))
    }

    func testDisplayTitleFallbackIsNotHardcodedInSource() throws {
        // Regression guard: the fallback once hardcoded "Chapter \(index)",
        // which showed English titles on pt-BR lock screens/readers.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // EpubToMp3Tests
            .deletingLastPathComponent()  // ios/EpubToMp3
        for relative in ["EpubToMp3/Models/EbookFulltext.swift",
                         "EpubToMp3/Models/JobSnapshot.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            XCTAssertFalse(
                source.contains("\"Chapter \\("),
                "\(relative) must localize the chapter fallback via L10n, not a hardcoded literal"
            )
        }
    }

    // MARK: - Round-trip encoding

    func testRoundTripsThroughEncoder() throws {
        let original = EbookFulltext(
            jobId: "j",
            bookTitle: "T",
            bookAuthor: "A",
            chapters: [
                EbookFulltext.Chapter(
                    index: 1, name: "Ch", text: "x",
                    html: nil, css: nil, charCount: 1, segments: nil
                )
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EbookFulltext.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
