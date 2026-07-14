import XCTest

final class TextKitLinkInteractionTests: XCTestCase {
    func testTextKitPageControllerSetsItselfAsTextViewDelegate() throws {
        let source = try textKitSource()

        XCTAssertTrue(
            source.contains("UITextViewDelegate"),
            "TextKitPageController must conform to UITextViewDelegate so page-curl mode can intercept link taps."
        )
        XCTAssertTrue(
            source.contains("textView.delegate = self"),
            "TextKitPageController must set textView.delegate = self or shouldInteractWith(url:) never fires."
        )
        XCTAssertTrue(
            source.contains("shouldInteractWith url: URL"),
            "TextKitPageController must implement textView(_:shouldInteractWith:in:interaction:) to route EPUB links through the reader."
        )
    }

    func testReaderViewPassesOnLinkTapIntoTextKitPageView() throws {
        let source = try readerViewSource()

        XCTAssertTrue(
            source.contains("onLinkTap: onLinkTap"),
            "ReaderView must pass onLinkTap into TextKitPageView so page-curl mode handles EPUB links instead of dropping them."
        )
    }

    func testTextKitPageControllerHasLongPressSentenceResolution() throws {
        let source = try textKitSource()

        XCTAssertTrue(
            source.contains("UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))"),
            "TextKitPageController must add a long-press recognizer to drive the page-curl tap-to-play feature (Bug 7/8)."
        )
        XCTAssertTrue(
            source.contains("longPress.require(toFail:"),
            "The long-press recognizer must require(toFail:) the text view's native selection long-press, so holding for a selection handle still wins over sentence resolution."
        )
        XCTAssertTrue(
            source.contains("func sentenceSpan(at location: CGPoint) -> SentenceSpan?"),
            "TextKitPageController must resolve a press location to a SentenceSpan via TextKit."
        )
    }

    func testReaderViewPassesSpansAndOnJumpToSentenceIntoTextKitPageView() throws {
        let source = try readerViewSource()

        XCTAssertTrue(
            source.contains("spans: spans,") && source.contains("onJumpToSentence: onJumpToSentence,"),
            "ReaderView must plumb spans + onJumpToSentence into TextKitPageView so page-curl mode gets the same 'Tocar daqui' flow as scroll mode."
        )
    }

    func testPageTapRecognizerDefersToTextLinks() throws {
        let source = try textKitSource()

        XCTAssertTrue(
            source.contains("shouldReceive touch: UITouch"),
            "The page-turn recognizer must inspect touches before it recognizes them."
        )
        XCTAssertTrue(
            source.contains("containsLink(at:"),
            "The page-turn recognizer must reject a touch landing on a text link so link navigation wins over page turns/chrome."
        )
    }

    private func textKitSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Views/TextKitPageView.swift"),
            encoding: .utf8
        )
    }

    private func readerViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Views/ReaderView.swift"),
            encoding: .utf8
        )
    }
}
