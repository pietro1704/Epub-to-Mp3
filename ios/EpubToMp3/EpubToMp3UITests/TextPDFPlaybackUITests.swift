import Foundation
import XCTest

#if DEBUG
@MainActor
final class TextPDFPlaybackUITests: XCTestCase {
    func testTextPDFStartsRealAudioFromTheToolbar() {
        let app = launchApp()
        defer { app.terminate() }
        _ = openSecondPage(in: app)
        let toolbarPlay = app.navigationBars.buttons["reader.listen"].firstMatch
        XCTAssertTrue(toolbarPlay.waitForExistence(timeout: 5) && toolbarPlay.isHittable)
        toolbarPlay.tap()
        assertPlayingPageTwo(app, attachmentName: "text-pdf-toolbar-playing")
    }

    func testTextPDFStartsRealAudioFromTappedText() {
        let app = launchApp()
        defer { app.terminate() }
        let pdf = openSecondPage(in: app)
        let textPlay = app.sheets.buttons["Play from here"].firstMatch
        // Leave a few alternatives for other safe areas and PDFKit scaling.
        for offset in [0.61, 0.56, 0.51, 0.67, 0.40, 0.72] {
            pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: CGFloat(offset))).tap()
            if textPlay.waitForExistence(timeout: 0.6) { break }
        }
        XCTAssertTrue(textPlay.exists && textPlay.isEnabled, "A text tap must offer playback without OCR")
        XCTAssertEqual(pdf.value as? String, "2 of 2")
        textPlay.tap()
        assertPlayingPageTwo(app, attachmentName: "text-pdf-tap-playing")
    }

    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestTextPDFSeed", Self.fixturePDF().base64EncodedString(),
            "-uiTestResetActiveReader", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-uiTestReaderLayout", "paginated", "-uiTestReaderShowPageNumbers",
            "-reader.recentTool.v1", "listen"
        ]
        app.launch()
        return app
    }

    private func openSecondPage(in app: XCUIApplication) -> XCUIElement {
        let initialPlayerClose = app.buttons["fullPlayer.close"].firstMatch
        if initialPlayerClose.exists && initialPlayerClose.isHittable { initialPlayerClose.tap() }
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        let tile = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "library.bookTile.", Self.bookTitle
        )).firstMatch
        for _ in 0..<8 where !tile.exists || !tile.isHittable { app.swipeUp() }
        XCTAssertTrue(tile.exists && tile.isHittable, "The fixture must be imported by the app on launch")
        tile.tap()

        let pdf = app.descendants(matching: .any)["reader.pdf"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 12))
        XCTAssertTrue(wait { ["1 of 2", "2 of 2"].contains(pdf.value as? String ?? "") })
        if (pdf.value as? String) == "1 of 2" { pdf.swipeLeft() }
        XCTAssertTrue(wait { (pdf.value as? String) == "2 of 2" })

        return pdf
    }

    private func assertPlayingPageTwo(_ app: XCUIApplication, attachmentName: String) {
        let open = app.buttons["miniPlayer.open"].firstMatch
        let transport = app.buttons["fullPlayer.playPause"].firstMatch
        let useSystemVoice = app.alerts.buttons["Listen with the system voice"].firstMatch
        XCTAssertTrue(wait(timeout: 35) {
            if useSystemVoice.exists && useSystemVoice.isEnabled && useSystemVoice.isHittable { useSystemVoice.tap() }
            let mini = app.buttons["miniPlayer.playPause"].firstMatch
            return [mini, transport].contains { $0.exists && $0.label == "Pause" }
        }, "Playback must reach the real native transport")
        if !transport.exists {
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            open.tap()
        }

        let chapter = app.staticTexts["fullPlayer.chapterAndVoice"].firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        XCTAssertTrue(chapter.label.contains("Page 2"), "Expected narration on page two, got \(chapter.label)")
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let initial = elapsed.label
        XCTAssertTrue(wait { elapsed.label != initial }, "The actual audio clock must advance")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(timeout: TimeInterval = 6, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private static let bookTitle = "PDF Playback Test Fixture"

    private static func fixturePDF() -> Data {
        func contents(page: Int) -> String {
            let line = page == 1
                ? "This is the first page of the audiobook fixture."
                : "This second page has selectable words for narration."
            let text = "BT\n/F1 17 Tf\n28 TL\n60 641 Td\n(\(line)) Tj\n"
                + String(repeating: "T* (\(line)) Tj\n", count: 19) + "ET\n"
            return "<< /Length \(text.utf8.count) >>\nstream\n\(text)endstream"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Lang (en-US) >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 540 720] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 540 720] /Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            contents(page: 1),
            contents(page: 2),
            "<< /Title (\(bookTitle)) >>"
        ]
        var bytes = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        let crossReference = bytes.count
        bytes.append(contentsOf: "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets {
            bytes.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8)
        }
        let trailer = "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 8 0 R >>\nstartxref\n\(crossReference)\n%%EOF\n"
        bytes.append(contentsOf: trailer.utf8)
        return bytes
    }
}
#endif
