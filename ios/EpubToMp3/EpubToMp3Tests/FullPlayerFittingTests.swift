#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class FullPlayerFittingTests: XCTestCase {
    private func fixture(size: CGSize, category: UIContentSizeCategory = .large) -> (UIView, FullPlayerContent) {
        let host = UIView(frame: CGRect(origin: .zero, size: size))
        let target = UIViewController()
        let action = #selector(UIViewController.viewDidLoad)
        let content = FullPlayerContent()
        content.install(in: host, actionTarget: target,
            actions: .init(closeTapped: action, scrubBegan: action, scrubChanged: action,
                scrubEnded: action, previousChapterTapped: action, skipBackTapped: action,
                playPauseTapped: action, skipForwardTapped: action, nextChapterTapped: action, tocTapped: action),
            traits: UITraitCollection(preferredContentSizeCategory: category))
        content.titleLabel.text = String(repeating: "A long book title with ação and café. ", count: 20)
        content.authorLabel.text = String(repeating: "Author name ", count: 12)
        content.chapterLabel.text = String(repeating: "Chapter title and active voice ", count: 20)
        content.elapsedLabel.text = "1:23:45"
        content.remainingLabel.text = "≈ -2:34:56"
        var configuration = content.rateButton.configuration
        configuration?.title = "1.25×"
        content.rateButton.configuration = configuration
        host.layoutIfNeeded()
        content.layoutView.layoutIfNeeded()
        return (host, content)
    }

    func testLongMetadataFitsPortraitWithoutAScrollSurface() {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 320, height: 568)] {
            let (host, content) = fixture(size: size)
            assertFits(content, in: host)
            XCTAssertGreaterThan(content.titleLabel.frame.height, 0)
            XCTAssertGreaterThan(content.chapterLabel.frame.height, 0)
        }
    }

    func testLandscapeReflowsMetadataBesideControls() {
        let (host, content) = fixture(size: CGSize(width: 568, height: 320))
        assertFits(content, in: host)
        let title = content.titleLabel.convert(content.titleLabel.bounds, to: host)
        let progress = content.slider.convert(content.slider.bounds, to: host)
        XCTAssertLessThanOrEqual(title.maxX, progress.minX)
    }

    func testAccessibilityTextStillFitsBothOrientationsAndRetainsFullMetadata() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 568, height: 320)] {
            let (host, content) = fixture(size: size, category: .accessibilityExtraExtraExtraLarge)
            assertFits(content, in: host)
            XCTAssertEqual(content.titleLabel.numberOfLines, 2)
            XCTAssertGreaterThan(content.titleLabel.text?.count ?? 0, 500)
            XCTAssertGreaterThan(content.authorLabel.text?.count ?? 0, 100)
        }
    }

    func testRelayoutAfterMetadataOrOrientationChangeDoesNotKeepOldFrames() {
        let (host, content) = fixture(size: CGSize(width: 390, height: 844))
        let originalCoverHeight = content.coverContainer.frame.height
        content.authorLabel.isHidden = true
        host.frame.size = CGSize(width: 844, height: 390)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        content.layoutView.setNeedsLayout()
        content.layoutView.layoutIfNeeded()
        assertFits(content, in: host)
        XCTAssertLessThan(content.coverContainer.frame.height, originalCoverHeight)
    }

    private func assertFits(_ content: FullPlayerContent, in host: UIView, file: StaticString = #filePath, line: UInt = #line) {
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        XCTAssertFalse(descendants(host).contains { $0 is UIScrollView }, file: file, line: line)
        let views: [UIView] = [content.closeButton, content.titleLabel, content.authorLabel, content.chapterLabel,
            content.slider, content.elapsedLabel, content.remainingLabel, content.previousChapterButton,
            content.skipBackButton, content.playPauseButton, content.skipForwardButton, content.nextChapterButton,
            content.rateButton, content.tocButton, content.sleepButton, content.airPlayContainer, content.volumeView]
        for view in views where !view.isHidden {
            let frame = view.convert(view.bounds, to: host)
            XCTAssertTrue(host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Outside viewport: \(view)", file: file, line: line)
            XCTAssertFalse(view.hasAmbiguousLayout, "Ambiguous layout: \(view)", file: file, line: line)
            if view is UIButton || view === content.slider || view === content.airPlayContainer {
                XCTAssertGreaterThanOrEqual(frame.height, 44, file: file, line: line)
                XCTAssertGreaterThanOrEqual(frame.width, 44, file: file, line: line)
            }
        }
        if !content.coverContainer.isHidden {
            XCTAssertEqual(content.coverContainer.frame.height / content.coverContainer.frame.width, 1.5, accuracy: 0.001, file: file, line: line)
        }
    }
}
#endif
