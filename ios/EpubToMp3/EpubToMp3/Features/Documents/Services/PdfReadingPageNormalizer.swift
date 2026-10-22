import CoreImage
import Foundation
import ImageIO
import PDFKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Converts scanned two-page spreads into upright, independently navigable PDF pages.
///
/// This is deliberately visual-only: text extraction and TTS retain their own
/// source pipeline. The reader receives a PDFKit document with the same
/// content, but each facing scan is a separate page in normal reading order.
enum PdfReadingPageNormalizer {
    typealias RecognizedLine = PdfSpreadDetection.RecognizedLine

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    /// Returns a replacement document only when the source is a sideways,
    /// scanned two-page spread. Normal PDFs keep their original PDFKit pages.
    static func normalizedDocument(from url: URL) -> PDFDocument? {
        if let cached = PdfNormalizedDocumentCache.document(for: url) {
            return cached
        }
        guard let document = PDFDocument(url: url) else { return nil }
        guard let normalized = normalizedDocument(from: document) else { return nil }
        PdfNormalizedDocumentCache.store(normalized, for: url)
        return normalized
    }

    static func normalizedDocument(from document: PDFDocument) -> PDFDocument? {
        guard document.pageCount > 0,
              PdfSpreadDetection.hasNoSelectableText(in: document),
              let orientation = PdfSpreadDetection.spreadOrientation(in: document)
        else {
            return nil
        }
        return separatedDocument(from: document, orientation: orientation)
    }

    /// Splits every physical source page after applying a known sideways scan
    /// orientation. This preserves the source's visual pagination, including
    /// intentionally blank logical pages. Kept internal so deterministic image
    /// geometry has a narrow XCTest seam independent of Vision OCR.
    static func separatedDocument(
        from document: PDFDocument,
        orientation: CGImagePropertyOrientation
    ) -> PDFDocument? {
        guard document.pageCount > 0,
              orientation == .left || orientation == .right else { return nil }
        let result = PDFDocument()
        for index in 0..<document.pageCount {
            guard let sourcePage = document.page(at: index),
                  let rendered = render(sourcePage),
                  let logicalPages = split(rendered, orientation: orientation),
                  logicalPages.count == 2
            else {
                return nil
            }
            for image in logicalPages {
                guard let page = makePDFPage(image: image) else { return nil }
                result.insert(page, at: result.pageCount)
            }
        }
        return result.pageCount == document.pageCount * 2 ? result : nil
    }

    static func isTwoUpSpread(_ lines: [RecognizedLine]) -> Bool {
        PdfSpreadDetection.isTwoUpSpread(lines)
    }

    private static func split(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> [CGImage]? {
        guard let normalized = normalizedImage(image, orientation: orientation) else {
            return nil
        }
        let extent = normalized.extent.integral
        guard extent.width > extent.height, extent.width >= 2, extent.height > 0 else {
            return nil
        }
        let halfWidth = floor(extent.width / 2)
        let leftRect = CGRect(x: extent.minX, y: extent.minY, width: halfWidth, height: extent.height)
        let rightRect = CGRect(
            x: extent.minX + halfWidth,
            y: extent.minY,
            width: extent.width - halfWidth,
            height: extent.height
        )
        guard let left = imageContext.createCGImage(normalized.cropped(to: leftRect), from: leftRect),
              let right = imageContext.createCGImage(normalized.cropped(to: rightRect), from: rightRect)
        else {
            return nil
        }
        return [left, right]
    }

    private static func normalizedImage(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> CIImage? {
        let oriented = CIImage(cgImage: image)
            .oriented(forExifOrientation: Int32(orientation.rawValue))
        let normalized = oriented.transformed(
            by: CGAffineTransform(
                translationX: -oriented.extent.minX,
                y: -oriented.extent.minY
            )
        )
        return normalized.extent.width > 0 && normalized.extent.height > 0 ? normalized : nil
    }

    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let size = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            let scaleX = size.width / bounds.width
            let scaleY = size.height / bounds.height
            context.cgContext.scaleBy(x: scaleX, y: scaleY)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()
        }.cgImage
        #else
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            let scaleX = size.width / bounds.width
            let scaleY = size.height / bounds.height
            context.scaleBy(x: scaleX, y: scaleY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    private static func makePDFPage(image: CGImage) -> PDFPage? {
        #if canImport(UIKit)
        PDFPage(image: UIImage(cgImage: image))
        #else
        PDFPage(
            image: NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        )
        #endif
    }

}
