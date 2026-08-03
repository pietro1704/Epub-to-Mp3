import XCTest

final class ReaderImmersiveModeTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try readSourceFileIfAvailable(
            at: root.appendingPathComponent("EpubToMp3/\(relativePath)")
        )
    }

    func testReaderPropagatesChromeVisibilityToItsHost() throws {
        let sourceText = try source("Features/Reader/Views/BookOpenScreenController.swift")
        let hostSource = try source("Features/Reader/Views/MainReaderScreenController.swift")

        XCTAssertTrue(sourceText.contains("var onChromeVisibilityChanged: ((Bool) -> Void)?"))
        XCTAssertTrue(sourceText.contains("onChromeVisibilityChanged?(chromeHidden)"))
        XCTAssertTrue(hostSource.contains("reader.onChromeVisibilityChanged"))
        XCTAssertTrue(hostSource.contains("onReaderChromeVisibilityChanged?(isHidden)"))
    }

    func testRootExpandsReaderWhenImmersiveChromeIsHidden() throws {
        let source = try source("App/IOSRootContainer.swift")

        XCTAssertTrue(source.contains("let hidesBottomChrome = isReaderLoading || isImmersiveReaderMode"))
        XCTAssertTrue(source.contains("readerBottomToMiniPlayer.isActive = !hidesBottomChrome"))
        XCTAssertTrue(source.contains("readerBottomToRoot.isActive = hidesBottomChrome"))
        XCTAssertTrue(source.contains("let miniShouldBeVisible = showMini && !isReaderLoading && !isImmersiveReaderMode"))
    }

    func testImmersiveReaderHidesSystemChromeAndUsesScreenEdges() throws {
        let rootSource = try source("App/IOSRootContainer.swift")
        let hostSource = try source("Features/Reader/Views/MainReaderScreenController.swift")
        let readerSource = try source("Features/Reader/Views/BookOpenScreenController.swift")

        XCTAssertTrue(rootSource.contains("override var prefersStatusBarHidden"))
        XCTAssertTrue(rootSource.contains("setNeedsStatusBarAppearanceUpdate()"))
        XCTAssertTrue(hostSource.contains("private var readerTopToRoot: NSLayoutConstraint!"))
        XCTAssertTrue(hostSource.contains("readerTopToRoot.isActive = !shouldShow"))
        XCTAssertTrue(readerSource.contains("func prepareForViewportTransition()"))
        XCTAssertTrue(readerSource.contains("restorePendingViewportAnchorIfNeeded()"))
    }

    func testOpeningBookBindsItToTheMiniPlayerWithoutStartingPlayback() throws {
        let source = try source("Features/Reader/Views/MainReaderScreenController.swift")

        XCTAssertTrue(source.contains("PlaybackBindingStore.setCurrentlyPlaying("))
        XCTAssertTrue(source.contains("bookID: book.id"))
        XCTAssertFalse(source.contains("player.play()"))
    }
}
