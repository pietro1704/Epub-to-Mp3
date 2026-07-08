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
