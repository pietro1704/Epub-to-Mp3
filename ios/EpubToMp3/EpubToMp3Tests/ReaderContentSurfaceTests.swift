#if os(iOS)
import PDFKit
import UIKit
import XCTest

@testable import EpubToMp3

@MainActor
final class ReaderContentSurfaceTests: XCTestCase {
    func testPDFSurfaceDeactivatesReaderContentAndRestoresTextWithoutCrash() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let textView = UITextView()
        let comicView = UIImageView()
        [textView, comicView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        let textConstraints = [
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        let comicConstraints = [
            comicView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            comicView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            comicView.topAnchor.constraint(equalTo: container.topAnchor),
            comicView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        let surface = ReaderContentSurface(textView: textView, comicPageImageView: comicView)

        surface.mountText(textConstraints: textConstraints, comicConstraints: comicConstraints)
        surface.mountPDF(
            at: URL(fileURLWithPath: "/tmp/reader-surface-test.pdf"),
            in: container,
            textConstraints: textConstraints,
            comicConstraints: comicConstraints
        )

        XCTAssertEqual(surface.kind, .pdf)
        XCTAssertTrue(textView.isHidden)
        XCTAssertFalse(textView.isUserInteractionEnabled)
        XCTAssertTrue(comicView.isHidden)
        XCTAssertFalse(comicView.isUserInteractionEnabled)
        XCTAssertTrue(textConstraints.allSatisfy { !$0.isActive })
        XCTAssertTrue(comicConstraints.allSatisfy { !$0.isActive })
        XCTAssertEqual(container.subviews.compactMap { $0 as? PDFView }.count, 1)

        surface.mountText(textConstraints: textConstraints, comicConstraints: comicConstraints)

        XCTAssertEqual(surface.kind, .text)
        XCTAssertFalse(textView.isHidden)
        XCTAssertTrue(textView.isUserInteractionEnabled)
        XCTAssertTrue(textConstraints.allSatisfy(\.isActive))
        XCTAssertTrue(container.subviews.compactMap { $0 as? PDFView }.isEmpty)
    }
}
#endif
