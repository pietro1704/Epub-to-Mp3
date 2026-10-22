import XCTest
@testable import EpubToMp3

final class EpubFallbackProjectionBoundaryTests: XCTestCase {
    func testArchivePathNormalizationRetainsTheContainingSpineDocument() {
        XCTAssertEqual(EpubArchivePath.normalize("OPS/Text/../Images/./cover.png"), "OPS/Images/cover.png")
        XCTAssertEqual(EpubArchivePath.normalize("../../Text/chapter one.xhtml"), "Text/chapter one.xhtml")
        XCTAssertEqual(EpubArchivePath.normalize("OPS/Text/chapter%20one.xhtml"), "OPS/Text/chapter%20one.xhtml")
    }

    func testTextProjectionPreservesParagraphsWhileExcludingExecutableContent() {
        let html = "<h1>Chapter &amp; One</h1><style>hidden style</style><p>First&#160;line</p><script>hidden script</script><p>Second line</p>"
        let text = EpubFallbackText.stripHTML(html)
        XCTAssertEqual(EpubFallbackText.firstHeading(in: html), "Chapter & One")
        XCTAssertTrue(text.contains("First line\nSecond line"))
        XCTAssertFalse(text.contains("hidden"))
        XCTAssertNil(EpubFallbackText.firstHeading(in: "<p>Only body text</p>"))
    }
}
