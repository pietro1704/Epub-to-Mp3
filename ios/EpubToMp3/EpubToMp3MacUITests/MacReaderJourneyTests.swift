import XCTest
import AppKit

/// Exercises normal library-to-reader navigation through the shipping AppKit
/// controls, using the dedicated sandboxed acceptance application and book.
@MainActor
final class MacReaderJourneyTests: XCTestCase {
    private var application: XCUIApplication?

    override func tearDownWithError() throws {
        if let app = application, app.state != .notRunning {
            app.typeKey(.escape, modifierFlags: [])
            app.terminate()
        }
        application = nil
    }

    func testImportedBookOpensDirectlyInReaderAndCrossesChapterBothWays() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let supplied = env["MAC_AUDIOBOOK_ACCEPTANCE_ROOT"], supplied.hasPrefix("/"),
              let data = env["MAC_AUDIOBOOK_APP_DATA"],
              data.hasSuffix("/Library/Containers/com.pietrocode.epubtomp3.acceptance/Data") else {
            throw XCTSkip("Requires explicitly prepared isolated acceptance data")
        }
        let root = URL(fileURLWithPath: supplied)
        let appURL = root.appendingPathComponent("acceptance-app/EpubToMp3.app")
        guard Bundle(url: appURL)?.bundleIdentifier == "com.pietrocode.epubtomp3.acceptance" else {
            throw XCTSkip("Requires the dedicated acceptance bundle identity")
        }
        let app = XCUIApplication(url: appURL)
        application = app
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { if app.state != .notRunning { app.terminate() } }
        XCTAssertTrue(app.buttons["library.add"].waitForExistence(timeout: 20))
        app.buttons["library.add"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.textFields["PathTextField"]
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        let path = root.appendingPathComponent("MacAcceptance.epub").path
        paste(path, into: pathField)
        XCTAssertEqual(pathField.value as? String, path)
        pathField.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: pathField)], timeout: 10), .completed)
        let open = app.buttons["OKButton"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: open)], timeout: 10), .completed)
        open.click()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.open.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        book.click()
        let content = app.descendants(matching: .any).matching(identifier: "reader.content").firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["reader.close"].exists)
        XCTAssertFalse(app.buttons["bookDetail.convert"].exists, "Opening a book must go directly to the reader")
        let title = app.staticTexts["reader.chapterTitle"]
        XCTAssertTrue(title.exists)
        let firstTitle = title.value as? String ?? title.label
        attach(app, name: "reader-imported-first-chapter")
        content.click()
        for _ in 0..<30 {
            app.typeKey(.rightArrow, modifierFlags: [])
            if (title.value as? String ?? title.label) != firstTitle { break }
        }
        XCTAssertNotEqual(title.value as? String ?? title.label, firstTitle,
            "Native page actions must reach the next chapter")
        attach(app, name: "reader-next-chapter")
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertEqual(title.value as? String ?? title.label, firstTitle,
            "Backward navigation at the boundary must restore the previous chapter")
        attach(app, name: "reader-previous-chapter-end")
        app.buttons["reader.close"].click()
        XCTAssertTrue(app.buttons["library.add"].waitForExistence(timeout: 10))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func paste(_ text: String, into element: XCUIElement) {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        board.clearContents()
        board.setString(text, forType: .string)
        let ownedChange = board.changeCount
        defer {
            if board.changeCount == ownedChange {
                board.clearContents()
                let items = saved.map { values in
                    let item = NSPasteboardItem()
                    values.forEach { item.setData($0.value, forType: $0.key) }
                    return item
                }
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey("v", modifierFlags: .command)
    }
}
