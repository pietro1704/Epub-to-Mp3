import XCTest
@testable import EpubToMp3

#if os(iOS)
final class ReaderViewportConfigurationTests: XCTestCase {
    func testPaginatedModeUsesPagedViewportAndPageIndicator() {
        let configuration = ReaderViewportConfiguration.resolve(
            layout: .paginated,
            chromeHidden: false,
            showsPageNumbers: true
        )

        XCTAssertFalse(configuration.allowsVerticalScrolling)
        XCTAssertFalse(configuration.allowsChapterSwipes)
        XCTAssertTrue(configuration.usesPaginatedTextHeight)
        XCTAssertTrue(configuration.showsPageIndicator)
    }

    func testScrollingModeAppliesImmediatelyWithoutPaginationChrome() {
        let configuration = ReaderViewportConfiguration.resolve(
            layout: .scrolling,
            chromeHidden: false,
            showsPageNumbers: true
        )

        XCTAssertTrue(configuration.allowsVerticalScrolling)
        XCTAssertTrue(configuration.allowsChapterSwipes)
        XCTAssertFalse(configuration.usesPaginatedTextHeight)
        XCTAssertFalse(configuration.showsPageIndicator)
    }

    func testHiddenChromeUsesTheSafeReaderSurfaceWithoutPageChrome() {
        let configuration = ReaderViewportConfiguration.resolve(
            layout: .paginated,
            chromeHidden: true,
            showsPageNumbers: true
        )

        XCTAssertFalse(configuration.usesScreenEdges)
        XCTAssertFalse(configuration.showsPageIndicator)
    }

    @MainActor
    func testReaderTextViewUsesTheTextKitOneLayoutObjectsRequiredForPagination() {
        let textView = ReaderTextViewFactory.make()

        XCTAssertNotNil(textView.textStorage.layoutManagers.first)
        XCTAssertTrue(textView.textStorage.layoutManagers.first === textView.layoutManager)
    }

    @MainActor
    func testImmersiveReaderKeepsTheSystemSafeAreaVisible() {
        XCTAssertFalse(
            IOSRootContainerController.shouldHideStatusBar(immersiveReaderMode: true)
        )
        XCTAssertFalse(
            IOSRootContainerController.shouldHideStatusBar(immersiveReaderMode: false)
        )
    }
}
#endif
