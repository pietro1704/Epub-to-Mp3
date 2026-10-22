import XCTest
@testable import EpubToMp3

#if os(macOS)
import AppKit

final class MacReaderLinkTests: XCTestCase {
    @MainActor
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

    @MainActor
    func testFootnoteLinkDefersMouseUpToTheTextSystemInsteadOfPaginating() throws {
        let url = try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "notes.xhtml#note-1"))
        let textView = MacReaderTextView()
        let contents = NSMutableAttributedString(string: "1")
        contents.addAttribute(.link, value: url, range: NSRange(location: 0, length: contents.length))
        textView.textStorage?.setAttributedString(contents)

        XCTAssertTrue(textView.shouldDeferMouseUpToTextSystem(at: 0))
        XCTAssertFalse(textView.shouldDeferMouseUpToTextSystem(at: 1))
    }

    @MainActor
    func testLinkCallbackKeepsUnicodeTextAndTheExactRequestedURL() throws {
        let url = try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "notes.xhtml#nota-2"))
        let textView = MacReaderTextView()
        let contents = NSMutableAttributedString(string: "😀 referêncía")
        let range = (contents.string as NSString).range(of: "referêncía")
        contents.addAttribute(.link, value: url, range: range)
        textView.textStorage?.setAttributedString(contents)
        var links: [(URL, String)] = []
        textView.onLinkClick = { received, text in links.append((received, text)); return true }

        XCTAssertTrue(textView.textView(textView, clickedOnLink: url, at: range.location))
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.0, url)
        XCTAssertEqual(links.first?.1, "referêncía")
        XCTAssertFalse(textView.shouldDeferMouseUpToTextSystem(at: contents.length))
    }
}
#endif
