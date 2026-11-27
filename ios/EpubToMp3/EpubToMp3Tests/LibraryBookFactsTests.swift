import XCTest
@testable import EpubToMp3

final class LibraryBookFactsTests: XCTestCase {
    private let added = Date(timeIntervalSince1970: 1_767_268_800) // 2026-01-01 12:00 UTC

    private func book(_ type: BookFileType, lastOpenedAt: Date? = nil) -> BookEntity {
        BookEntity(id: "facts", title: "Facts", bookmark: Data([1]), displayFilename: "facts",
                   addedAt: added, lastOpenedAt: lastOpenedAt, fileType: type)
    }

    private func lines(_ facts: LibraryBookFacts, _ localization: String = "en") throws -> [String] {
        facts.lines(bundle: try XCTUnwrap(L10n.localizationBundle(localization)),
                    locale: Locale(identifier: localization == "en" ? "en_US" : localization),
                    timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))
    }

    func testChapterBookShowsEveryKnownFact() throws {
        var facts = LibraryBookFacts(book: book(.epub, lastOpenedAt: added.addingTimeInterval(86_400)))
        facts.chapterCount = 20
        facts.languageCode = "pt-BR"
        facts.progress = .init(index: 6, total: 20, fraction: 0.4)
        facts.audio = .init(ready: 12, total: 63)
        facts.audioSeconds = 3 * 3600 + 12 * 60

        XCTAssertEqual(try lines(facts), [
            "EPUB · 20 chapters · Portuguese (Brazil)",
            "32% · ch. 7 of 20",
            "Audio 12 of 63 · 3 h 12 min",
            "Added 1/1/26",
            "Read 1/2/26",
        ])
    }

    func testPagedBookCountsPagesAndSaysItWasNeverConverted() throws {
        var facts = LibraryBookFacts(book: book(.pdf))
        facts.pageCount = 1
        facts.chapterCount = 9
        facts.audio = .init(ready: 0, total: nil)
        facts.audioSeconds = 90

        XCTAssertEqual(try lines(facts), ["PDF · 1 page", "Not converted", "Added 1/1/26"])
    }

    func testUnknownFactsAreLeftOut() throws {
        XCTAssertEqual(try lines(LibraryBookFacts(book: book(.epub))), ["EPUB", "Added 1/1/26"])
    }

    func testComicsHaveNoAudioLine() throws {
        var facts = LibraryBookFacts(book: book(.cbz))
        facts.audio = .notConverted
        XCTAssertEqual(try lines(facts), ["CBZ", "Added 1/1/26"])
    }

    func testAudioIsCompleteOnlyAgainstAKnownTotal() throws {
        XCTAssertEqual(LibraryBookFacts.Audio(ready: 63, total: 63), .complete)
        XCTAssertEqual(LibraryBookFacts.Audio(ready: 3, total: nil), .partial(ready: 3, total: nil))
        var facts = LibraryBookFacts(book: book(.pdf))
        facts.audio = .partial(ready: 3, total: nil)
        facts.audioSeconds = 20
        XCTAssertEqual(try lines(facts)[1], "Audio: 3 chapters ready · 1 min")
    }

    func testProgressRejectsPlacesOutsideTheBook() {
        XCTAssertNil(LibraryBookFacts.Progress(index: 20, total: 20, fraction: 0))
        XCTAssertNil(LibraryBookFacts.Progress(index: 0, total: 0, fraction: 0))
        XCTAssertEqual(LibraryBookFacts.Progress(index: 19, total: 20, fraction: 1)?.percent, 100)
    }

    func testPortugueseAndSpanishShipEveryLine() throws {
        var facts = LibraryBookFacts(book: book(.pdf, lastOpenedAt: added))
        facts.pageCount = 20
        facts.progress = .init(index: 6, total: 20, fraction: 1)
        facts.audio = .complete
        for localization in ["pt-BR", "es"] {
            let shown = try lines(facts, localization)
            XCTAssertEqual(shown.count, 5, localization)
            XCTAssertFalse(shown.contains { $0.contains("library.facts") }, "\(localization): \(shown)")
        }
        XCTAssertEqual(try lines(facts, "pt-BR")[1], "35% · p. 7 de 20")
    }
}
