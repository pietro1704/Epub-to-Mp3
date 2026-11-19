import XCTest
@testable import EpubToMp3

final class LocalizationFormattingTests: XCTestCase {
    func testKnownKeyDoesNotLeakLocalizationKey() {
        XCTAssertEqual(L10n.string("app.name"), "Epub-to-Mp3")
        XCTAssertNotEqual(L10n.string("menu.file"), "menu.file")
    }

    func testReaderChapterFormatsAnInteger() {
        let label = L10n.string("reader.chapter", 7)

        XCTAssertTrue(label.contains("7"))
    }
}
