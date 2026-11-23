import XCTest

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@testable import EpubToMp3

final class ReaderInlineImageLayoutTests: XCTestCase {
    func testFitsOversizedImageAndSkipsUnchangedLayout() {
        let attachment = NSTextAttachment()
        attachment.image = makeImage(width: 200, height: 100)
        let source = NSMutableAttributedString(string: "Before ")
        source.append(NSAttributedString(attachment: attachment))

        let fitted = ReaderInlineImageLayout.fitting(source, maximumWidth: 80)

        XCTAssertNotNil(fitted)
        XCTAssertEqual(attachment.bounds.size.width, 80, accuracy: 0.001)
        XCTAssertEqual(attachment.bounds.size.height, 40, accuracy: 0.001)
        XCTAssertNil(
            ReaderInlineImageLayout.fitting(
                fitted ?? source,
                maximumWidth: 80
            ),
            "A repeated layout pass must not copy an unchanged chapter."
        )
    }

    /// A portrait image whose width-fitted height exceeds the page is a fragment taller than the usable page: the
    /// paginated layout then falls back to scrolling and edge taps stop turning pages. It is capped to the page.
    func testTallPortraitImageIsCappedToThePageHeightKeepingItsAspect() {
        let attachment = NSTextAttachment()
        attachment.image = makeImage(width: 600, height: 1_600)
        let source = NSMutableAttributedString(string: "Plate ")
        source.append(NSAttributedString(attachment: attachment))

        let fitted = ReaderInlineImageLayout.fitting(source, maximumWidth: 330, maximumHeight: 600)

        XCTAssertNotNil(fitted)
        XCTAssertLessThanOrEqual(attachment.bounds.size.height, 600.001)
        XCTAssertEqual(attachment.bounds.size.height, 600, accuracy: 0.001)
        XCTAssertEqual(attachment.bounds.size.width / attachment.bounds.size.height, 600.0 / 1_600.0, accuracy: 0.001)
        XCTAssertNil(ReaderInlineImageLayout.fitting(fitted ?? source, maximumWidth: 330, maximumHeight: 600),
                     "A repeated pass must not copy an unchanged chapter.")
    }

    func testImagesThatAlreadyFitTheHeightKeepTheWidthOnlyBehaviour() {
        let attachment = NSTextAttachment()
        attachment.image = makeImage(width: 200, height: 100)
        let source = NSMutableAttributedString(string: "Before ")
        source.append(NSAttributedString(attachment: attachment))
        _ = ReaderInlineImageLayout.fitting(source, maximumWidth: 80, maximumHeight: 600)
        XCTAssertEqual(attachment.bounds.size.width, 80, accuracy: 0.001)
        XCTAssertEqual(attachment.bounds.size.height, 40, accuracy: 0.001)
    }

    private func makeImage(width: CGFloat, height: CGFloat) -> PlatformImage {
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { _ in }
        #else
        NSImage(size: CGSize(width: width, height: height))
        #endif
    }
}

#if canImport(UIKit)
private typealias PlatformImage = UIImage
#else
private typealias PlatformImage = NSImage
#endif
