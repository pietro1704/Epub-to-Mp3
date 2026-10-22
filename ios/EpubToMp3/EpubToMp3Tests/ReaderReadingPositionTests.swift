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
        let document = ReaderBookDocument(book: BookEntity(
            id: suite, title: "Raw offset", bookmark: Data([1]),
            displayFilename: "position.epub", addedAt: Date()
        ))
        var hidden = false
        let restored = expectation(description: "Final layout restores position")
        let position = ReaderReadingPosition(document: document, composition: composition,
            facts: { .init(chromeHidden: hidden, isPaginated: false, isLoading: false, layoutResult: nil) },
            send: { event in
                if case .updatePageIndicator = event { restored.fulfill() }
            })
        position.prepareForViewportTransition()
        XCTAssertTrue(position.isViewportTransitioning)
        XCTAssertEqual(position.pendingViewportAnchor?.viewportOffset, 137.25)
        hidden = true
        composition.scrollView.bounds.size.height = 500
        composition.scrollView.contentOffset = .zero
        position.completeViewportTransition()
        XCTAssertTrue(position.isViewportTransitioning, "Restoration waits for final main-loop geometry")
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertFalse(position.isViewportTransitioning)
        XCTAssertNil(position.pendingViewportAnchor)
        XCTAssertEqual(composition.scrollView.contentOffset.y, 137.25, accuracy: 0.001)
    }
}
#endif
