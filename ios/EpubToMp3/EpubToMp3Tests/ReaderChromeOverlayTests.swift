import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

@MainActor
final class ReaderChromeOverlayTests: XCTestCase {
    func testChromeRoundTripsPreserveTheActualNativeReadingViewport() throws {
        let text = String(repeating: "A complete sentence keeps its reading position across chrome changes. ", count: 160)
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter(text)])
        harness.installTeardown(in: self)
        harness.showChapter(0)
        #if os(iOS)
        harness.controller.view.layoutIfNeeded()
        harness.text.layoutCommittedViewport()
        let viewport = harness.composition.scrollView
        viewport.setContentOffset(CGPoint(x: 0, y: 137.25), animated: false)
        let size = viewport.bounds.size
        let offset = viewport.contentOffset
        let pages = harness.text.paginatedPageOffsets
        for hidden in [true, false, true, false] {
            harness.text.chromeHidden = hidden
            harness.text.applyReaderLayoutMode()
            harness.controller.view.layoutIfNeeded()
            XCTAssertEqual(viewport.bounds.size, size)
            XCTAssertEqual(viewport.contentOffset, offset)
            XCTAssertEqual(harness.text.paginatedPageOffsets, pages)
        }
        #else
        harness.controller.view.layoutSubtreeIfNeeded()
        let viewport = harness.composition.contentScrollView
        let size = viewport.contentView.bounds.size
        let origin = viewport.contentView.bounds.origin
        for hidden in [true, false, true, false] {
            harness.composition.setChromeHidden(hidden)
            harness.controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(viewport.contentView.bounds.size, size)
            XCTAssertEqual(viewport.contentView.bounds.origin, origin)
        }
        #endif
    }
}
