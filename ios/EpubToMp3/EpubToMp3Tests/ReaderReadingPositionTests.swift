#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderReadingPositionTests: XCTestCase {
    func testChromeTransitionRestoresExactFractionalRawOffsetAfterFinalLayout() async throws {
        let suite = "reader-raw-position-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = UIViewController()
        controller.loadViewIfNeeded()
        let selector = #selector(UIViewController.viewDidLoad)
        let composition = ReaderViewComposition(
            view: controller.view, target: controller,
            actions: .init(readerTap: selector, chapterForward: selector, chapterBackward: selector,
                toggleChromeAccessibility: selector, horizontalSwipe: selector, resetFlicker: selector,
                toggleChrome: selector, pageLeft: selector, pageRight: selector,
                previousChapter: selector, nextChapter: selector, retryLoading: selector),
            settings: AppSettings(defaults: defaults), onUpdateFlicker: {}, onPDFPageReady: { _ in }
        )
        composition.scrollView.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        composition.scrollView.contentSize = CGSize(width: 320, height: 2_000)
        composition.loadingContainer.isHidden = true
        composition.scrollView.contentOffset = CGPoint(x: 0, y: 137.25)
        // UIKit may align an assigned offset to the device's pixel grid.
        // The viewport contract preserves the accepted raw position exactly.
        let originalOffset = composition.scrollView.contentOffset
        let document = ReaderBookDocument(book: BookEntity(
            id: suite, title: "Raw offset", bookmark: Data([1]),
            displayFilename: "position.epub", addedAt: Date()
        ))
        var hidden = false
        let restored = expectation(description: "Final layout restores position")
        let position = ReaderReadingPosition(document: document, composition: composition, location: ReaderLocation(defaults: defaults),
            facts: { .init(chromeHidden: hidden, isPaginated: false, isLoading: false, layoutResult: nil) },
            send: { event in
                if case .updatePageIndicator = event { restored.fulfill() }
            })
        position.prepareForViewportTransition()
        XCTAssertTrue(position.isViewportTransitioning)
        XCTAssertEqual(position.pendingViewportAnchor?.viewportOffset, originalOffset.y)
        hidden = true
        composition.scrollView.bounds.size.height = 500
        composition.scrollView.contentOffset = .zero
        position.completeViewportTransition()
        XCTAssertTrue(position.isViewportTransitioning, "Restoration waits for final main-loop geometry")
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertFalse(position.isViewportTransitioning)
        XCTAssertNil(position.pendingViewportAnchor)
        XCTAssertEqual(composition.scrollView.contentOffset, originalOffset)
    }

    /// READER-CHROME-TOGGLE-TEXT-JUMP: pages turned while the chrome was in one state must survive every later toggle.
    func testChromeTogglesKeepThePageReachedByPageTurnsSinceTheLastToggle() async throws {
        let suite = "reader-toggle-position-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = UIViewController()
        controller.loadViewIfNeeded()
        let selector = #selector(UIViewController.viewDidLoad)
        let composition = ReaderViewComposition(
            view: controller.view, target: controller,
            actions: .init(readerTap: selector, chapterForward: selector, chapterBackward: selector,
                toggleChromeAccessibility: selector, horizontalSwipe: selector, resetFlicker: selector,
                toggleChrome: selector, pageLeft: selector, pageRight: selector,
                previousChapter: selector, nextChapter: selector, retryLoading: selector),
            settings: AppSettings(defaults: defaults), onUpdateFlicker: {}, onPDFPageReady: { _ in }
        )
        composition.scrollView.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        composition.scrollView.contentSize = CGSize(width: 320, height: 2_000)
        composition.loadingContainer.isHidden = true
        let document = ReaderBookDocument(book: BookEntity(
            id: suite, title: "Toggle", bookmark: Data([1]),
            displayFilename: "toggle.epub", addedAt: Date()
        ))
        var hidden = false
        var restored: XCTestExpectation?
        let position = ReaderReadingPosition(document: document, composition: composition, location: ReaderLocation(defaults: defaults),
            facts: { .init(chromeHidden: hidden, isPaginated: true, isLoading: false, layoutResult: nil) },
            send: { event in
                if case .updatePageIndicator = event { restored?.fulfill() }
            })
        func toggleChrome() async {
            let done = expectation(description: "Chrome toggle restored")
            restored = done
            position.prepareForViewportTransition()
            hidden.toggle()
            position.completeViewportTransition()
            await fulfillment(of: [done], timeout: 2)
            restored = nil
        }
        func turnPage(to offset: CGFloat) {
            composition.scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }

        turnPage(to: 300)
        await toggleChrome()
        turnPage(to: 900)
        for tap in 1...3 {
            await toggleChrome()
            XCTAssertEqual(composition.scrollView.contentOffset.y, 900, "tap \(tap) moved the text")
        }
        turnPage(to: 1_200)
        for tap in 1...2 {
            await toggleChrome()
            XCTAssertEqual(composition.scrollView.contentOffset.y, 1_200, "later tap \(tap) moved the text")
        }
    }
}
#endif
