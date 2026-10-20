import XCTest
@testable import EpubToMp3

#if os(iOS)
import UIKit

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

    @MainActor
    func testForwardPageFoldsAroundTheBookSpineAndBackwardPageUnfolds() throws {
        try withAnimatedReader(longFirstChapter: true) { controller, textView, scrollView in
            XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.bounds.height * 2)
            controller.perform(NSSelectorFromString("turnPageRight"))
            let forward = try XCTUnwrap(pageCurl(in: controller.view))
            XCTAssertEqual(forward.layer.anchorPoint.x, 0, accuracy: 0.001,
                           "The forward page must fold around the left book spine.")
            XCTAssertEqual(forward.layer.transform.m11, 0, accuracy: 0.01)
            XCTAssertGreaterThan(scrollView.contentOffset.y, 0)
            settleAnimation(controller)
            controller.perform(NSSelectorFromString("turnPageLeft"))
            let backward = try XCTUnwrap(pageCurl(in: controller.view))
            XCTAssertEqual(backward.layer.anchorPoint.x, 0, accuracy: 0.001)
            XCTAssertTrue(CATransform3DIsIdentity(backward.layer.transform),
                          "The previous page must unfold into view, ending flat rather than folding away.")
            XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.5)
            XCTAssertTrue(textView.text.hasPrefix("First chapter."))
            settleAnimation(controller)
            XCTAssertNil(pageCurl(in: controller.view), "Animation must remove its transient surface.")
        }
    }

    @MainActor
    func testTurningPageRetainsTheViewportGlyphMasks() throws {
        try withAnimatedReader(longFirstChapter: true) { controller, _, scrollView in
            // A chrome restoration may leave an exact raw offset between
            // canonical boundaries; its partial fragments must stay masked.
            scrollView.setContentOffset(CGPoint(x: 0, y: 11), animated: false)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let masks = controller.view.subviews.filter {
                $0.accessibilityElementsHidden && !$0.isHidden && $0.backgroundColor != nil
            }
            XCTAssertFalse(masks.isEmpty, "The fixture must require a glyph-protection mask.")
            let frame = scrollView.convert(scrollView.bounds, to: controller.view)
            let expected = masks.map { ($0.frame.offsetBy(dx: -frame.minX, dy: -frame.minY), $0.backgroundColor) }
            controller.perform(NSSelectorFromString("turnPageRight"))
            let page = try XCTUnwrap(pageCurl(in: controller.view))
            for (rect, color) in expected {
                XCTAssertTrue(page.subviews.contains { $0.frame == rect && $0.backgroundColor == color },
                              "The turning snapshot must protect the same partial glyphs as its source viewport.")
            }
            settleAnimation(controller)
        }
    }

    @MainActor
    func testBothChapterBoundaryDirectionsUseThePageAnimation() throws {
        try withAnimatedReader(longFirstChapter: false) { controller, textView, scrollView in
            controller.perform(NSSelectorFromString("turnPageRight"))
            XCTAssertNotNil(pageCurl(in: controller.view),
                            "Crossing into the next chapter must retain the configured animation.")
            XCTAssertTrue(textView.text.hasPrefix("Second chapter."))
            XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.5)
            settleAnimation(controller)
            controller.perform(NSSelectorFromString("turnPageLeft"))
            let backward = try XCTUnwrap(pageCurl(in: controller.view))
            XCTAssertTrue(CATransform3DIsIdentity(backward.layer.transform))
            XCTAssertTrue(textView.text.hasPrefix("First chapter."))
            settleAnimation(controller)
        }
    }

    @MainActor
    private func pageCurl(in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == "reader.pageCurl" { return view }
        return view.subviews.lazy.compactMap { self.pageCurl(in: $0) }.first
    }

    @MainActor
    private func settleAnimation(_ controller: UIViewController) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        controller.view.layoutIfNeeded()
    }

    @MainActor
    private func withAnimatedReader(
        longFirstChapter: Bool,
        verify: (BookOpenScreenController, UITextView, UIScrollView) throws -> Void
    ) throws {
        let id = "ReaderPageAnimation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
                          "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
                          "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
                          "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"]
        let savedWidget = widgetKeys.map { widget?.object(forKey: $0) }
        let first = "First chapter.\n\n" + (longFirstChapter ? String(repeating:
            "A traveller followed the winding river through a quiet valley.\n\n", count: 90) : "A short passage.")
        let second = "Second chapter. A different short passage."
        LocalFulltextCache.save(EbookFulltext(
            jobId: id, bookTitle: "Animation regression", bookAuthor: nil,
            chapters: [
                .init(index: 1, name: "First chapter", text: first, html: nil, css: nil,
                      charCount: first.count, segments: nil),
                .init(index: 2, name: "Second chapter", text: second, html: nil, css: nil,
                      charCount: second.count, segments: nil),
            ]), bookId: id)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        settings.pageTurnStyle = .flip
        let controller = BookOpenScreenController(
            book: BookEntity(id: id, title: "Animation regression", bookmark: Data(),
                             displayFilename: "animation.epub", addedAt: Date()),
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), settings: settings,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), player: player)
        let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previousKeyWindow?.windowScene ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first,
            "The reader animation requires a connected native window scene.")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(true)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            player.stop()
            window.isHidden = true
            window.rootViewController = nil
            LocalFulltextCache.evict(bookId: id)
            ReaderProgressStore.evict(bookId: id)
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            for (key, value) in zip(widgetKeys, savedWidget) { widget?.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: id)
            previousKeyWindow?.makeKey()
        }
        var loaded = false
        controller.onLoadStateChanged = { loaded = !$0 }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let deadline = Date().addingTimeInterval(3)
        while !loaded, Date() < deadline {
            controller.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(loaded)
        settleAnimation(controller)
        func findText(in view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap { findText(in: $0) }.first
        }
        let textView = try XCTUnwrap(findText(in: controller.view))
        var ancestor = textView.superview
        while ancestor != nil, !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        let scrollView = try XCTUnwrap(ancestor as? UIScrollView)
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("turnPageRight")))
        XCTAssertTrue(scrollView.window === window,
                      "The actual animated scroll surface must be attached to the visible native window.")
        XCTAssertFalse(window.isHidden)
        XCTAssertFalse(UIAccessibility.isReduceMotionEnabled,
                       "Animation regression requires Reduce Motion disabled; its fallback has separate coverage.")
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-uiTestReduceMotion"))
        XCTAssertEqual(settings.pageTurnStyle, .flip)
        XCTAssertTrue(UIView.areAnimationsEnabled)
        XCTAssertNotNil(scrollView.snapshotView(afterScreenUpdates: false),
                        "The live reader must provide a snapshot before testing fold geometry.")
        try verify(controller, textView, scrollView)
    }

}
#endif
