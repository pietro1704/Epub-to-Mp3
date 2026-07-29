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
        let source = try source("Features/Reader/Views/BookOpenScreenController.swift")
        let hostSource = try source("Features/Reader/Views/MainReaderScreenController.swift")

        XCTAssertTrue(source.contains("var onChromeVisibilityChanged: ((Bool) -> Void)?"))
        XCTAssertTrue(source.contains("onChromeVisibilityChanged?(chromeHidden)"))
        XCTAssertTrue(hostSource.contains("reader.onChromeVisibilityChanged"))
        XCTAssertTrue(hostSource.contains("onReaderChromeVisibilityChanged?(isHidden)"))
    }

    func testRootExpandsReaderWhenImmersiveChromeIsHidden() throws {
        let source = try source("App/IOSRootContainer.swift")

        XCTAssertTrue(source.contains("readerBottomToMiniPlayer.isActive = !isHidden"))
        XCTAssertTrue(source.contains("readerBottomToRoot.isActive = isHidden"))
        XCTAssertTrue(source.contains("miniPlayerController.view.isHidden = !showMini || isImmersiveReaderMode"))
    }

    func testOpeningBookBindsItToTheMiniPlayerWithoutStartingPlayback() throws {
        let source = try source("Features/Reader/Views/MainReaderScreenController.swift")

        XCTAssertTrue(source.contains("PlaybackBindingStore.setCurrentlyPlaying("))
        XCTAssertTrue(source.contains("bookID: book.id"))
        XCTAssertFalse(source.contains("player.play()"))
    }
}
