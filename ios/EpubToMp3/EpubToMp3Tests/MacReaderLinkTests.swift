import XCTest
@testable import EpubToMp3

#if os(macOS)
import AppKit

@MainActor
final class MacReaderLinkTests: XCTestCase {
    func testFootnoteEPUBLinkIsHandledBeforeAppKitCanOpenItExternally() throws {
        let url = try XCTUnwrap(
            EpubHtmlRenderer.readerLinkURL(for: "LordoftheRings_foot-1.xhtml#ref52")
        )
        let textView = MacReaderTextView()
        let contents = NSMutableAttributedString(string: "52")
        contents.addAttribute(.link, value: url, range: NSRange(location: 0, length: contents.length))
        textView.textStorage?.setAttributedString(contents)

        var handledURL: URL?
        var handledText: String?
        textView.onLinkClick = { receivedURL, linkText in
            handledURL = receivedURL
            handledText = linkText
            return true
        }

        let wasHandled = textView.textView(textView, clickedOnLink: url, at: 0)

        XCTAssertTrue(wasHandled)
        XCTAssertEqual(handledURL, url)
        XCTAssertEqual(handledText, "52")
    }

    func testFootnoteLinkDefersMouseUpToTheTextSystemInsteadOfPaginating() throws {
        let url = try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "notes.xhtml#note-1"))
        let textView = MacReaderTextView()
        let contents = NSMutableAttributedString(string: "1")
        contents.addAttribute(.link, value: url, range: NSRange(location: 0, length: contents.length))
        textView.textStorage?.setAttributedString(contents)

        XCTAssertTrue(textView.shouldDeferMouseUpToTextSystem(at: 0))
        XCTAssertFalse(textView.shouldDeferMouseUpToTextSystem(at: 1))
    }
}
#endif
