#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderTextLayoutTests: XCTestCase {
    func testFitsTextIntoViewportWhenDocumentViewStartsAtZero() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = MacReaderTextView(frame: .zero, textContainer: nil)
        textView.string = "Visible reader text. " + String(repeating: "More text. ", count: 400)
        scrollView.documentView = textView

        MacReaderTextLayout.fit(textView, in: scrollView)

        XCTAssertEqual(textView.frame.width, scrollView.contentView.bounds.width)
        XCTAssertGreaterThan(textView.frame.height, 0)
        XCTAssertNotNil(textView.textContainer)
        XCTAssertNotNil(textView.textStorage)
        XCTAssertGreaterThan(textView.layoutManager!.usedRect(for: textView.textContainer!).height, 0)
    }
}
#endif
