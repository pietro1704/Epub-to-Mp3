import XCTest
@testable import EpubToMp3

final class LocalizationFormattingTests: XCTestCase {
    func testReaderChapterFormatsAnInteger() {
        let label = L10n.string("reader.chapter", 7)

        XCTAssertTrue(label.contains("7"))
    }
}
