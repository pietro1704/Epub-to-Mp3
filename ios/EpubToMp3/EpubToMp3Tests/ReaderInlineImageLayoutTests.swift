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
