import XCTest

#if DEBUG
/// One automated pass over the PDF reader on a device, with a synthetic book in an isolated
/// launch: library index, settings, widget data and the imported book copy are throwaway.
/// On iOS the sandbox is shared, so caches made while reading that book can remain.
/// Every touch first checks that the app is in the foreground and that no system alert covers it.
/// The lock-screen widget itself is outside the app and stays a manual check; the player clock
/// and chapter title verified here are the values published to it.
@MainActor
final class PDFBatchDeviceUITests: XCTestCase {
    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        super.tearDown()
    }

    func testPDFOpensRotatesNarratesAndReportsChapterProgress() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-uiTestIsolatedSettings", "-uiTestTextPDFSeed", Self.fixturePDF().base64EncodedString(),
            "-uiTestResetActiveReader", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-uiTestReaderLayout", "paginated", "-uiTestReaderShowPageNumbers",
            "-reader.recentTool.v1", "listen"
        ]
        app.launch()

        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        tap(library)
        let tile = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "library.bookTile.", Self.bookTitle
        )).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "The synthetic PDF must be in the isolated library")
        tap(tile)

        // The first page is an image only: the book opens and no OCR failure is shown.
        let pdf = app.descendants(matching: .any)["reader.pdf"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 20))
        assertNoOCRFailure()
        XCTAssertTrue(wait { (pdf.value as? String)?.hasSuffix("of 3") == true })
        if pdf.value as? String == "1 of 3" {
            guardForeground()
            pdf.swipeLeft()
        }
        XCTAssertTrue(wait { pdf.value as? String == "2 of 3" })
        capture("pdf-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(wait { self.app.frame.width > self.app.frame.height })
        XCTAssertTrue(wait { pdf.value as? String == "2 of 3" }, "Rotating keeps the page")
        XCTAssertGreaterThan(pdf.frame.width, app.frame.width * 0.8)
        Thread.sleep(forTimeInterval: 1)
        capture("pdf-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(wait { self.app.frame.height > self.app.frame.width })
        XCTAssertTrue(wait { pdf.value as? String == "2 of 3" })

        let listen = app.navigationBars.buttons["reader.listen"].firstMatch
        XCTAssertTrue(listen.waitForExistence(timeout: 5))
        tap(listen)
        waitForPlayback()
        assertNoOCRFailure()
        let close = app.buttons["fullPlayer.close"].firstMatch
        if close.exists && close.isHittable { tap(close) }
        // The fixture skips its image-only page. The app says so in an alert, which blocks every later touch.
        let notice = app.alerts.containing(NSPredicate(format: "label CONTAINS %@", "without selectable text")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "The skipped page must be reported")
        tap(notice.buttons["OK"])
        // Highlight position samples: the page is short, so consecutive frames show it moving.
        for sample in 1...4 {
            Thread.sleep(forTimeInterval: 1.5)
            capture("pdf-highlight-sample-\(sample)")
        }

        let open = app.buttons["miniPlayer.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        tap(open)
        let chapter = app.staticTexts["fullPlayer.chapterAndVoice"].firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        XCTAssertFalse(chapter.label.contains("✤"), "A decoration line is not a title: \(chapter.label)")
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        let remaining = app.staticTexts["fullPlayer.remaining"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5) && remaining.exists)
        XCTAssertTrue(wait(timeout: 10) { !remaining.label.contains("--") && remaining.label != "0:00" },
                      "The chapter needs a duration, got \(remaining.label)")
        let first = elapsed.label
        XCTAssertTrue(wait(timeout: 10) { elapsed.label != first }, "The chapter clock must advance")
        capture("pdf-player-title-and-progress")
        tap(app.buttons["fullPlayer.close"].firstMatch)

        // The reader turns to the next page when the narration reaches it.
        XCTAssertTrue(wait(timeout: 90) { pdf.value as? String == "3 of 3" },
                      "The page must follow the narration, still on \(pdf.value ?? "?")")
        capture("pdf-followed-to-next-page")
    }

    private func waitForPlayback() {
        let useSystemVoice = app.alerts.buttons["Listen with the system voice"].firstMatch
        XCTAssertTrue(wait(timeout: 40) {
            if useSystemVoice.exists && useSystemVoice.isHittable {
                self.guardForeground()
                useSystemVoice.tap()
            }
            return ["miniPlayer.playPause", "fullPlayer.playPause"].contains {
                let button = self.app.buttons[$0].firstMatch
                return button.exists && button.label == "Pause"
            }
        }, "Playback must start")
    }

    private func assertNoOCRFailure() {
        let failure = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@",
            "no selectable text on any page", "requires verified OCR"))
        XCTAssertEqual(failure.count, 0, "A PDF with text pages must not report that it needs OCR")
    }

    private func tap(_ element: XCUIElement) {
        guardForeground()
        element.tap()
    }

    /// Best effort: XCUITest cannot promise to expose every system overlay.
    private func guardForeground() {
        XCTAssertEqual(app.state, .runningForeground, "The app is not in the foreground; stopping")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "A system alert is present; stopping")
        let foreign = NSPredicate(format: "identifier CONTAINS[c] 'notification' OR identifier CONTAINS[c] 'banner' "
            + "OR identifier CONTAINS[c] 'pictureinpicture' OR label CONTAINS[c] 'picture in picture'")
        XCTAssertFalse(springboard.descendants(matching: .any).matching(foreign).firstMatch.exists,
                       "A notification or floating window is present; stopping")
    }

    /// Captures the app window only, never other apps or system overlays outside it.
    private func capture(_ name: String) {
        guardForeground()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private static let bookTitle = "PDF Batch Fixture"

    /// Page 1 is a drawing without text; page 2 starts with a decoration line before its heading.
    private static func fixturePDF() -> Data {
        func stream(_ text: String) -> String { "<< /Length \(text.utf8.count) >>\nstream\n\(text)endstream" }
        func textPage(_ lines: [String]) -> String {
            stream("BT\n/F1 17 Tf\n28 TL\n60 641 Td\n"
                + lines.enumerated().map { ($0.offset == 0 ? "" : "T* ") + "(\($0.element)) Tj\n" }.joined()
                + "ET\n")
        }
        func page(_ contents: Int) -> String {
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 540 720] "
                + "/Resources << /Font << /F1 6 0 R >> >> /Contents \(contents) 0 R >>"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Lang (en-US) >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            page(7), page(8), page(9),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            stream("0.2 0.4 0.7 rg\n90 160 360 400 re f\n"),
            textPage(["* * * * * * * *", "Chapter One",
                      "A quiet lantern shines over the river.",
                      "The second sentence follows the first one.",
                      "A third sentence closes this short page."]),
            textPage(["The story continues on the next page.",
                      "Another sentence keeps the narration going."]),
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
        let trailer = "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info \(objects.count) 0 R >>\n"
            + "startxref\n\(crossReference)\n%%EOF\n"
        bytes.append(contentsOf: trailer.utf8)
        return bytes
    }
}
#endif
