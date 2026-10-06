#if os(iOS)
import UIKit
import XCTest

@testable import EpubToMp3

@MainActor
final class BookOpenChapterNavigationTests: XCTestCase {
    func testBackwardChapterCrossingLandsOnTheLastRenderedPage() throws {
        try verifyChapterBoundaries(readerFontSize: 3)
    }

    func testBackwardChapterCrossingAtSmallFontLandsOnTheLastRenderedPage() throws {
        try verifyChapterBoundaries(readerFontSize: 0)
    }

    private func verifyChapterBoundaries(readerFontSize: Int) throws {
        let identifier = "BookOpenChapterNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [
            ReaderSessionState.currentlyReadingBookIDKey,
            AudioPlayer.readerCurrentChapterIndexDefaultsKey,
            AudioPlayer.readerCurrentPageRatioDefaultsKey,
            AudioPlayer.readerCurrentSentenceIdDefaultsKey,
        ]
        let savedDefaults = keys.map { ($0, standard.object(forKey: $0)) }
        let firstText = "First chapter.\n\n" + String(repeating:
            "A traveller followed the winding river through the quiet valley. "
            + "Trees shaded the path while distant hills rose above the water.\n\n",
            count: 60
        )
        let secondText = "Second chapter. A short passage that fits on one page."
        let thirdText = "Third chapter. Another short passage for the single-page boundary."
        let payload = EbookFulltext(
            jobId: identifier, bookTitle: "Chapter navigation", bookAuthor: nil,
            chapters: [
                .init(index: 1, name: "First chapter", text: firstText,
                      html: nil, css: nil, charCount: firstText.count, segments: nil),
                .init(index: 2, name: "Second chapter", text: secondText,
                      html: nil, css: nil, charCount: secondText.count, segments: nil),
                .init(index: 3, name: "Third chapter", text: thirdText,
                      html: nil, css: nil, charCount: thirdText.count, segments: nil),
            ]
        )
        LocalFulltextCache.save(payload, bookId: identifier)
        let player = AudioPlayer(resumeStore: ResumeStore(
            storage: UserDefaultsResumeStorage(defaults: defaults)
        ))
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        settings.pageTurnStyle = .none
        settings.readerFontSize = readerFontSize
        let controller = BookOpenScreenController(
            book: BookEntity(id: identifier, title: "Chapter navigation", bookmark: Data(),
                             displayFilename: "chapter-navigation.epub", addedAt: Date()),
            library: LibraryStore(defaults: defaults, defaultsKey: "library"),
            settings: settings,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            player: player
        )
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        defer {
            window.isHidden = true
            window.rootViewController = nil
            player.stop()
            LocalFulltextCache.evict(bookId: identifier)
            ReaderProgressStore.evict(bookId: identifier)
            for (key, value) in savedDefaults { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: identifier)
            previousKeyWindow?.makeKey()
        }
        var loadingFinished = false
        controller.onLoadStateChanged = { loadingFinished = !$0 }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let loadDeadline = Date().addingTimeInterval(3)
        while !loadingFinished, Date() < loadDeadline {
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(loadingFinished, "The cached real reader must finish loading.")

        func settleLayout() {
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
        }
        settleLayout()
        func findTextView(in view: UIView) -> UITextView? {
            if let textView = view as? UITextView { return textView }
            return view.subviews.lazy.compactMap { findTextView(in: $0) }.first
        }
        let textView = try XCTUnwrap(findTextView(in: controller.view))
        var ancestor = textView.superview
        while ancestor != nil, !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        let scrollView = try XCTUnwrap(ancestor as? UIScrollView)
        func measuredLayout() -> ReaderPaginatedTextLayout.Result {
            ReaderPaginatedTextLayout.layout(.init(
                layoutManager: textView.layoutManager,
                textContainer: textView.textContainer,
                topInset: textView.textContainerInset.top,
                bottomInset: textView.textContainerInset.bottom,
                pageHeight: scrollView.bounds.height
            ))
        }
        func assertNoClippedFragments(_ layout: ReaderPaginatedTextLayout.Result) {
            let offset = scrollView.contentOffset.y
            let clipped = layout.clippingReport(at: offset).clippedFragments
            XCTAssertEqual(clipped.count, 0,
                "offset=\(offset), pageHeight=\(layout.pageHeight), bottomInset=\(layout.bottomInset), "
                + "contentHeight=\(layout.contentHeight), clipped=\(clipped), "
                + "topMask=\(String(describing: layout.topOverflowMaskRange(at: offset))), "
                + "bottomMask=\(String(describing: layout.bottomOverflowMaskRange(at: offset)))")
        }
        let initialLayout = measuredLayout()
        XCTAssertFalse(initialLayout.requiresScrollingFallback)
        XCTAssertGreaterThan(initialLayout.canonicalPageOffsets.count, 1,
                             "The previous chapter must have multiple real rendered pages.")
        XCTAssertTrue(textView.text.hasPrefix("First chapter."))
        XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.5)

        let backward = NSSelectorFromString("turnPageLeft")
        let forward = NSSelectorFromString("turnPageRight")
        XCTAssertTrue(controller.responds(to: backward))
        XCTAssertTrue(controller.responds(to: forward))
        controller.perform(backward)
        settleLayout()
        XCTAssertTrue(textView.text.hasPrefix("First chapter."), "Back at the book start is a no-op.")
        XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.5)

        // Exercise the production page action through every canonical page,
        // including the final-page-to-next-chapter boundary.
        for _ in 0..<60 {
            if textView.text.hasPrefix("Second chapter.") { break }
            controller.perform(forward)
            settleLayout()
        }
        guard textView.text.hasPrefix("Second chapter.") else {
            return XCTFail("Forward page actions did not reach the second chapter.")
        }
        XCTAssertEqual(measuredLayout().canonicalPageOffsets.count, 1)
        XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.5,
                       "Forward crossing must start at the next chapter's first page.")

        controller.perform(backward)
        settleLayout()
        XCTAssertTrue(textView.text.hasPrefix("First chapter."))
        let finalLayout = measuredLayout()
        let expectedOffset = try XCTUnwrap(finalLayout.canonicalPageOffsets.last)
        XCTAssertGreaterThan(expectedOffset, 0)
        XCTAssertEqual(scrollView.contentOffset.y, expectedOffset, accuracy: 0.5,
                       "Back from page one must land on the previous chapter's final canonical page, not its beginning.")
        assertNoClippedFragments(finalLayout)

        // Returning repeatedly must reuse the newly measured destination,
        // not the page count from the short chapter we just left.
        for _ in 0..<2 {
            controller.perform(forward)
            settleLayout()
            XCTAssertTrue(textView.text.hasPrefix("Second chapter."))
            XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.5)
            controller.perform(backward)
            settleLayout()
            XCTAssertTrue(textView.text.hasPrefix("First chapter."))
            XCTAssertEqual(scrollView.contentOffset.y, expectedOffset, accuracy: 0.5)
            assertNoClippedFragments(measuredLayout())
        }

        controller.perform(forward)
        settleLayout()
        XCTAssertTrue(textView.text.hasPrefix("Second chapter."))
        controller.perform(forward)
        settleLayout()
        XCTAssertTrue(textView.text.hasPrefix("Third chapter."))
        controller.perform(backward)
        settleLayout()
        XCTAssertTrue(textView.text.hasPrefix("Second chapter."))
        XCTAssertEqual(measuredLayout().canonicalPageOffsets.count, 1)
        XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.5,
                       "A single-page previous chapter has the same first and final canonical page.")
    }
}
#endif
