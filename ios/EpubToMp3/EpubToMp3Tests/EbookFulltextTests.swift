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

    func testDecodesOptionalCanonicalSpeechTextWithoutChangingReaderText() throws {
        let json = """
        {
          "jobId": "j",
          "chapters": [{
            "index": 1,
            "name": "Ch",
            "text": "Reader text",
            "speechText": "Chapter one...\\n\\nNarration"
          }]
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(EbookFulltext.self, from: json)

        XCTAssertEqual(payload.chapters.first?.text, "Reader text")
        XCTAssertEqual(payload.chapters.first?.speechText, "Chapter one...\n\nNarration")
    }

    func testIgnoresUnknownFields() throws {
        let json = """
        {"jobId": "j", "chapters": [], "futureField": 42}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(EbookFulltext.self, from: json)
        XCTAssertEqual(payload.jobId, "j")
        XCTAssertEqual(payload.chapters.count, 0)
    }

    func testDecodesOptionalImageResourcesWithoutChangingLegacyPayloads() throws {
        let json = """
        {
          "jobId": "j",
          "chapters": [{
            "index": 1, "name": "Ch", "text": "abc",
            "resources": [{"href": "images/cover%20art.jpg", "mediaType": "image/jpeg", "dataBase64": "AQI="}]
          }]
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(EbookFulltext.self, from: json)
        XCTAssertEqual(payload.chapters.first?.resources?.first?.href, "images/cover%20art.jpg")
        XCTAssertEqual(payload.chapters.first?.resources?.first?.mediaType, "image/jpeg")
        XCTAssertEqual(payload.chapters.first?.resources?.first?.dataBase64, "AQI=")
    }

    func testDecodesOptionalFootnotesWithoutChangingLegacyPayloads() throws {
        let json = """
        {
          "jobId": "j",
          "chapters": [{
            "index": 1, "name": "Ch", "text": "abc",
            "footnotes": [{"number": "1", "text": "See appendix A."}]
          }]
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(EbookFulltext.self, from: json)
        XCTAssertEqual(payload.chapters.first?.footnotes?.first?.number, "1")
        XCTAssertEqual(payload.chapters.first?.footnotes?.first?.text, "See appendix A.")
    }

    func testDecodesNestedTocWithResolvedChapterIndex() throws {
        let json = """
        {
          "jobId": "j",
          "chapters": [{"index": 1, "name": "Ch 1", "text": "abc"}],
          "toc": [
            {"title": "Part One", "level": 1, "chapterIndex": null, "children": [
              {"title": "Chapter 1", "level": 2, "chapterIndex": 1, "children": []}
            ]}
          ]
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(EbookFulltext.self, from: json)
        XCTAssertEqual(payload.toc?.count, 1)
        XCTAssertEqual(payload.toc?.first?.title, "Part One")
        XCTAssertNil(payload.toc?.first?.chapterIndex)
        XCTAssertEqual(payload.toc?.first?.children.first?.chapterIndex, 1)
    }

    func testMissingTocDecodesAsNil() throws {
        let json = """
        {"jobId": "j", "chapters": []}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(EbookFulltext.self, from: json)
        XCTAssertNil(payload.toc)
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

    // MARK: - displayTitle fidelity

    func testDisplayTitlePreservesPublisherSpelling() {
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "parteI", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "parteI")
    }

    func testDisplayTitlePreservesPublisherDigits() {
        let chapter = EbookFulltext.Chapter(
            index: 3, name: "Chapter3", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "Chapter3")
    }

    func testDisplayTitlePreservesAllUppercase() {
        // All-uppercase like "PROLOGUE" should NOT be lowercased — it stays
        // as-is because the condition `result == result.lowercased()` is false.
        let chapter = EbookFulltext.Chapter(
            index: 0, name: "PROLOGUE", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "PROLOGUE")
    }

    func testDisplayTitlePreservesLowercase() {
        let chapter = EbookFulltext.Chapter(
            index: 2, name: "os primeiros", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "os primeiros")
    }

    func testDisplayTitleLeavesAlreadyCleanUnchanged() {
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "Chapter 1", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "Chapter 1")
    }

    func testDisplayTitleReplacesGeneratedChapterLabelWithEmbeddedHeading() {
        let chapter = EbookFulltext.Chapter(
            index: 1,
            name: "Capítulo 1",
            text: "A cidade",
            html: "<h1>A cidade</h1><p>Conteúdo</p>",
            css: nil,
            charCount: 10,
            segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "A cidade")
    }

    func testDisplayTitleUsesFirstTextHeadingWhenHTMLIsUnavailable() {
        let chapter = EbookFulltext.Chapter(
            index: 13,
            name: "Chapter 13",
            text: "The Long Road\n\nThe story begins here.",
            html: nil,
            css: nil,
            charCount: 42,
            segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "The Long Road")
    }

    func testDisplayTitlePreservesWhitespace() {
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "  Intro  ", text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        XCTAssertEqual(chapter.displayTitle, "  Intro  ")
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
        for relative in ["EpubToMp3/Features/Reader/Models/EbookFulltext.swift",
                         "EpubToMp3/Features/Conversion/Models/JobSnapshot.swift"] {
            let source = try readSourceFileIfAvailable(at: root.appendingPathComponent(relative))
            XCTAssertFalse(
                source.contains("\"Chapter \\("),
                "\(relative) must localize the chapter fallback via L10n, not a hardcoded literal"
            )
        }
    }

    func testCachedChapterWithoutBodyIsNotReadable() {
        let empty = EbookFulltext.Chapter(
            index: 1, name: "Chapter 1", text: "   ",
            html: "\n", css: nil, charCount: 0, segments: nil
        )
        let plain = EbookFulltext.Chapter(
            index: 1, name: "Chapter 1", text: "Readable text",
            html: nil, css: nil, charCount: 13, segments: nil
        )
        XCTAssertFalse(empty.hasReadableContent)
        XCTAssertTrue(plain.hasReadableContent)
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
