import XCTest
@testable import EpubToMp3

/// The reader's contents tool is named in the listener's language, not with the "TOC" abbreviation.
@MainActor
final class ReaderContentsToolTitleTests: XCTestCase {
    func testContentsToolIsNamedInWords() {
        XCTAssertEqual(ReaderTool.contents.title, L10n.string("reader.contents"))
        XCTAssertNotEqual(ReaderTool.contents.title, "TOC")
    }
}
