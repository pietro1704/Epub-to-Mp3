import XCTest
@testable import EpubToMp3

/// PLAYER-GO-TO-READING-PAGE: the expanded player offers "Go to reading" only while the reader is NOT showing
/// the narrated passage.
@MainActor
final class ReaderNarrationPairingTests: XCTestCase {
    func testPairedOnlyWhenTheSpokenCharacterIsOnTheVisiblePageOfTheSameChapter() {
        let page = NSRange(location: 1_000, length: 800)
        XCTAssertTrue(ReaderNarrationPairing.isPaired(spokenChapter: 3, spokenOffset: 1_000, readerChapter: 3, visible: page))
        XCTAssertTrue(ReaderNarrationPairing.isPaired(spokenChapter: 3, spokenOffset: 1_799, readerChapter: 3, visible: page))
        XCTAssertFalse(ReaderNarrationPairing.isPaired(spokenChapter: 3, spokenOffset: 1_800, readerChapter: 3, visible: page),
                       "The first character after the page is on the next page")
        XCTAssertFalse(ReaderNarrationPairing.isPaired(spokenChapter: 3, spokenOffset: 999, readerChapter: 3, visible: page))
        XCTAssertFalse(ReaderNarrationPairing.isPaired(spokenChapter: 3, spokenOffset: 1_200, readerChapter: 4, visible: page),
                       "Another chapter is never paired, even when offsets coincide")
    }

    func testAnythingUnknownIsUnpaired() {
        let page = NSRange(location: 0, length: 100)
        XCTAssertFalse(ReaderNarrationPairing.isPaired(spokenChapter: nil, spokenOffset: 5, readerChapter: 0, visible: page))
        XCTAssertFalse(ReaderNarrationPairing.isPaired(spokenChapter: 0, spokenOffset: nil, readerChapter: 0, visible: page))
        XCTAssertFalse(ReaderNarrationPairing.isPaired(spokenChapter: 0, spokenOffset: 5, readerChapter: nil, visible: page))
        XCTAssertFalse(ReaderNarrationPairing.isPaired(spokenChapter: 0, spokenOffset: 5, readerChapter: 0, visible: nil))
        XCTAssertFalse(ReaderNarrationPairing.isPaired(spokenChapter: 0, spokenOffset: 5, readerChapter: 0,
                                                      visible: NSRange(location: NSNotFound, length: 0)))
    }

    func testPDFIsPairedWhenTheNarratedPageIsOneOfTheVisiblePages() {
        XCTAssertTrue(ReaderNarrationPairing.isPaired(spokenPage: 4, visiblePages: [3, 4]))
        XCTAssertFalse(ReaderNarrationPairing.isPaired(spokenPage: 5, visiblePages: [3, 4]))
        XCTAssertFalse(ReaderNarrationPairing.isPaired(spokenPage: nil, visiblePages: [3, 4]))
        XCTAssertFalse(ReaderNarrationPairing.isPaired(spokenPage: 0, visiblePages: []))
    }

    func testAReleasedReaderCannotClobberItsSuccessor() {
        let pairing = ReaderNarrationPairing()
        let old = NSObject(), new = NSObject()
        pairing.publish(paired: true, owner: ObjectIdentifier(old))
        pairing.publish(paired: true, owner: ObjectIdentifier(new))
        pairing.release(owner: ObjectIdentifier(old))
        XCTAssertTrue(pairing.isPaired, "The old reader no longer owns the state")
        pairing.release(owner: ObjectIdentifier(new))
        XCTAssertFalse(pairing.isPaired)
    }

    func testPublishingOnlyChangesTheStateWhenItDiffers() {
        let pairing = ReaderNarrationPairing()
        var emissions = 0
        let token = pairing.$isPaired.dropFirst().sink { _ in emissions += 1 }
        defer { token.cancel() }
        XCTAssertFalse(pairing.isPaired)
        pairing.publish(paired: false)
        pairing.publish(paired: true)
        pairing.publish(paired: true)
        pairing.publish(paired: false)
        XCTAssertEqual(emissions, 2)
    }

    func testTheButtonIsLocalizedInEveryLanguage() {
        let expected = ["en": "Go to reading", "pt-BR": "Ir para a leitura", "es": "Ir a la lectura"]
        for (language, text) in expected {
            let path = Bundle(for: AudioPlayer.self).path(forResource: language, ofType: "lproj")
            let bundle = path.flatMap(Bundle.init(path:))
            XCTAssertEqual(bundle?.localizedString(forKey: "player.goToReading", value: nil, table: nil), text, language)
        }
    }
}
