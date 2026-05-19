import Foundation
import PDFKit

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Generates tiny synthetic PDF files for unit tests. PDFKit gives us
/// a writeable `PDFDocument` API directly — much simpler than the
/// hand-rolled ZIP writer needed for EPUB fixtures.
enum PdfFixture {

    static let title = "Test PDF Title"
    static let author = "Test PDF Author"

    /// Build a one-page PDF with the supplied metadata. Caller is
    /// responsible for deleting the returned URL.
    static func createSinglePage(
        title: String = title,
        author: String = author,
        bodyText: String = "Lorem ipsum dolor sit amet."
    ) throws -> URL {
        try createMultiPage(
            title: title,
            author: author,
            pages: [(heading: title, body: bodyText)]
        )
    }

    /// Build a multi-page PDF where each page has its own heading + body
    /// text. Used by `PdfTextExtractorTests` to verify the heading
    /// heuristic groups pages into chapters.
    static func createMultiPage(
        title: String = title,
        author: String = author,
        pages: [(heading: String, body: String)]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-fixture-\(UUID().uuidString).pdf")

        let document = PDFDocument()
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: title,
            PDFDocumentAttribute.authorAttribute: author,
        ]

        for (i, page) in pages.enumerated() {
            let pdfPage = renderPage(
                heading: page.heading,
                body: page.body
            )
            document.insert(pdfPage, at: i)
        }

        guard document.write(to: url) else {
            throw NSError(
                domain: "PdfFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "PDFDocument.write returned false"]
            )
        }
        return url
    }

    // MARK: - Page rendering

    private static let pageSize = CGSize(width: 612, height: 792) // US Letter

    /// Draw a "heading + body" page via the platform's PDF renderer.
    /// Headings use 28pt bold so the `PdfTextExtractor` heading-
    /// heuristic threshold (≥ 1.4× body avg of 12pt = 16.8pt) trips.
    private static func renderPage(heading: String, body: String) -> PDFPage {
        #if canImport(UIKit)
        let format = UIGraphicsPDFRendererFormat()
        let bounds = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let headingAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 28),
            ]
            NSString(string: heading).draw(
                at: CGPoint(x: 72, y: 72),
                withAttributes: headingAttrs
            )
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
            ]
            NSString(string: body).draw(
                in: CGRect(x: 72, y: 140, width: pageSize.width - 144, height: 600),
                withAttributes: bodyAttrs
            )
        }
        // `PDFDocument(data:)` always yields exactly one page for the
        // bytes UIGraphicsPDFRenderer produces — the renderer was given
        // a single `beginPage()` call.
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else {
            return PDFPage()
        }
        return page
        #elseif canImport(AppKit)
        // Draw into a real PDF `CGContext` — NOT an NSImage bitmap.
        // `PDFPage(image:)` produces a raster page with no extractable
        // text, so `PdfTextExtractor` would throw `noTextRecovered`.
        // A CG PDF context keeps the glyphs as selectable text, which
        // is what the extractor (and PDFKit `page.string`) needs.
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            return PDFPage()
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return PDFPage()
        }
        ctx.beginPDFPage(nil)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        NSColor.white.setFill()
        NSRect(origin: .zero, size: pageSize).fill()
        let headingAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 28),
            .foregroundColor: NSColor.black,
        ]
        NSString(string: heading).draw(
            at: NSPoint(x: 72, y: pageSize.height - 100),
            withAttributes: headingAttrs
        )
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black,
        ]
        NSString(string: body).draw(
            in: NSRect(x: 72, y: 100, width: pageSize.width - 144, height: 500),
            withAttributes: bodyAttrs
        )
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data),
              let page = doc.page(at: 0) else {
            return PDFPage()
        }
        return page
        #else
        return PDFPage()
        #endif
    }
}
