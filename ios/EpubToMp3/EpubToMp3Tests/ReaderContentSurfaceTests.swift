#if os(iOS)
import PDFKit
import UIKit
import XCTest

@testable import EpubToMp3

@MainActor
final class ReaderContentSurfaceTests: XCTestCase {
    private func makeSurface() -> (ReaderContentSurface, UIView, UITextView, UIImageView) {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let scrollView = UIScrollView(frame: container.bounds)
        let textView = UITextView()
        let comicView = UIImageView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let surface = ReaderContentSurface(
            readerView: container,
            scrollView: scrollView,
            textView: textView,
            comicPageImageView: comicView
        )
        surface.install()
        return (surface, container, textView, comicView)
    }

    func testPDFSurfaceDeactivatesReaderContentAndRestoresTextWithoutCrash() throws {
        let (surface, container, textView, comicView) = makeSurface()

        surface.mount(.pdf(URL(fileURLWithPath: "/tmp/reader-surface-test.pdf")))

        XCTAssertEqual(surface.kind, .pdf)
        XCTAssertTrue(textView.isHidden)
        XCTAssertFalse(textView.isUserInteractionEnabled)
        XCTAssertTrue(comicView.isHidden)
        XCTAssertFalse(comicView.isUserInteractionEnabled)
        let pdfView = try XCTUnwrap(container.subviews.compactMap { $0 as? PDFView }.first)
        XCTAssertEqual(pdfView.displayMode, .singlePageContinuous)
        XCTAssertEqual(pdfView.displayDirection, .vertical)

        surface.mount(.text)

        XCTAssertEqual(surface.kind, .text)
        XCTAssertFalse(textView.isHidden)
        XCTAssertTrue(textView.isUserInteractionEnabled)
        XCTAssertTrue(container.subviews.compactMap { $0 as? PDFView }.isEmpty)
    }

    func testComicSurfaceMakesTextInactiveAndRestoresOneActiveSurface() {
        let (surface, container, textView, comicView) = makeSurface()

        surface.mount(.comic)

        XCTAssertEqual(surface.kind, .comic)
        XCTAssertTrue(textView.isHidden)
        XCTAssertFalse(textView.isUserInteractionEnabled)
        XCTAssertFalse(comicView.isHidden)
        XCTAssertTrue(comicView.isUserInteractionEnabled)
        XCTAssertTrue(container.subviews.compactMap { $0 as? PDFView }.isEmpty)

        surface.mount(.text)

        XCTAssertEqual(surface.kind, .text)
        XCTAssertFalse(textView.isHidden)
        XCTAssertTrue(textView.isUserInteractionEnabled)
        XCTAssertTrue(comicView.isHidden)
        XCTAssertFalse(comicView.isUserInteractionEnabled)
    }

    func testReplacingPDFDoesNotAccumulateViews() {
        let (surface, container, _, _) = makeSurface()

        surface.mount(.pdf(URL(fileURLWithPath: "/tmp/reader-surface-first.pdf")))
        surface.mount(.pdf(URL(fileURLWithPath: "/tmp/reader-surface-second.pdf")))

        XCTAssertEqual(surface.kind, .pdf)
        XCTAssertEqual(container.subviews.compactMap { $0 as? PDFView }.count, 1)
    }
}
#endif
