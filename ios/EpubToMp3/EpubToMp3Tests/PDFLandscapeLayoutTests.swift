#if os(iOS)
import PDFKit
import UIKit
import XCTest
@testable import EpubToMp3

/// A landscape reader shows the PDF page across the available width and scrolls within it,
/// instead of shrinking the whole page into the middle of a wide empty band.
@MainActor
final class PDFLandscapeLayoutTests: XCTestCase {
    private static let portrait = CGSize(width: 390, height: 760)
    private static let landscape = CGSize(width: 750, height: 340)

    func testScrollingPDFFillsTheLandscapeWidth() throws {
        try assertLandscapeFillsWidth(layout: .scrolling)
    }

    func testPaginatedPDFFillsTheLandscapeWidth() throws {
        try assertLandscapeFillsWidth(layout: .paginated)
    }

    private func assertLandscapeFillsWidth(layout: ReaderLayout, file: StaticString = #filePath,
                                           line: UInt = #line) throws {
        let url = try PdfFixture.createMultiPage(pages: [
            (heading: "First page", body: "A synthetic page read in landscape."),
            (heading: "Second page", body: "Another synthetic page.")])
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "pdf-landscape-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = layout
        let host = UIViewController()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        let previousWindow = scene?.windows.first(where: \.isKeyWindow)
        window.frame = CGRect(origin: .zero, size: Self.portrait)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        let view = ReaderPDFView(frame: CGRect(origin: .zero, size: Self.portrait))
        host.view.addSubview(view)
        let pdf = ReaderPDFPresentation(view: view, bookID: "landscape", defaults: defaults, settings: settings)
        pdf.load(document: try XCTUnwrap(PDFDocument(url: url)),
                 metadata: try ConverterFFIAdapter().openBook(at: url).metadataJSON)
        settle(view)

        func pageFrame() throws -> CGRect {
            let page = try XCTUnwrap(view.currentPage)
            return view.convert(page.bounds(for: view.displayBox), from: page)
        }

        view.frame.size = Self.landscape
        settle(view)
        let wide = try pageFrame()
        XCTAssertEqual(pdf.currentPage, 0, "Rotating keeps the page", file: file, line: line)
        XCTAssertGreaterThan(wide.width, Self.landscape.width * 0.9,
                             "The page must fill the landscape width, got \(wide)", file: file, line: line)
        XCTAssertLessThanOrEqual(wide.width, Self.landscape.width + 1,
                                 "The page must not be cut at the sides, got \(wide)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(wide.minY, -1, "The top of the page starts visible, got \(wide)",
                                    file: file, line: line)
        XCTAssertLessThan(wide.minY, Self.landscape.height * 0.15,
                          "No empty band above the page, got \(wide)", file: file, line: line)

        view.frame.size = Self.portrait
        settle(view)
        let tall = try pageFrame()
        XCTAssertEqual(pdf.currentPage, 0, "Rotating back keeps the page", file: file, line: line)
        XCTAssertLessThanOrEqual(tall.width, Self.portrait.width + 1,
                                 "Portrait shows the whole width, got \(tall)", file: file, line: line)
        XCTAssertGreaterThan(tall.width, Self.portrait.width * 0.9,
                             "Portrait fills the width, got \(tall)", file: file, line: line)
    }

    private func settle(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }
}
#endif
