import Foundation
import PDFKit

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Best-effort PDF metadata reader. PDFKit ships with iOS 11+ / macOS 10.4+,
/// so we lean on `PDFDocument` for both metadata extraction and the
/// rendered cover thumbnail.
///
/// Mirrors the shape of `EpubMetadataReader.Payload` so `LibraryStore`
/// can call either reader interchangeably.
enum PdfMetadataReader {

    /// Errors surfaced when the PDF is unreadable. Currently the only
    /// recoverable case is "encrypted with a password we don't have" —
    /// PDFKit returns `isEncrypted == true && !unlock(withPassword: "")`
    /// for those.
    enum ReaderError: Error, LocalizedError {
        case openFailed(String)
        case encrypted(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let name):
                return "PDFKit could not open \(name). The file may be malformed or corrupt."
            case .encrypted(let name):
                return "\(name) is password-protected. Remove the password (Preview → File → Export) before importing."
            }
        }
    }

    struct Payload {
        var title: String?
        var author: String?
        var cover: Data?
        var pageCount: Int

        init(
            title: String? = nil,
            author: String? = nil,
            cover: Data? = nil,
            pageCount: Int = 0
        ) {
            self.title = title
            self.author = author
            self.cover = cover
            self.pageCount = pageCount
        }
    }

    /// Parse the PDF at `url` and return a metadata snapshot suitable
    /// for `LibraryStore.importBook`. Throws when the PDF is encrypted
    /// (locked) or malformed enough that `PDFDocument(url:)` rejects
    /// it; in every other case it returns whatever it could find,
    /// falling back to the filename for the title.
    static func readMetadata(from url: URL) throws -> Payload {
        guard let document = PDFDocument(url: url) else {
            throw ReaderError.openFailed(url.lastPathComponent)
        }

        // Encrypted PDFs let us peek at the page count but `string` on
        // every page returns nil. We surface a user-friendly error so
        // the importer can prompt the user to strip the password.
        if document.isEncrypted && !document.unlock(withPassword: "") {
            throw ReaderError.encrypted(url.lastPathComponent)
        }

        var payload = Payload(pageCount: document.pageCount)

        // documentAttributes is a [PDFDocumentAttribute: Any] but the
        // SDK exposes it as [AnyHashable: Any] in Swift. Pull out the
        // common dc-equivalent fields by raw string keys so we don't
        // depend on the typed constants which moved between releases.
        if let attrs = document.documentAttributes {
            payload.title = stringValue(attrs, key: PDFDocumentAttribute.titleAttribute.rawValue)
            payload.author = stringValue(attrs, key: PDFDocumentAttribute.authorAttribute.rawValue)
        }

        // Filename-based fallback heuristic when documentAttributes is
        // empty: many CLI-exported PDFs (LaTeX, Pandoc, browser print)
        // leave the title blank. Use the first non-blank line of page 1
        // when it looks short enough to be a title (<= 120 chars).
        if payload.title == nil, let firstPage = document.page(at: 0),
           let pageText = firstPage.string {
            for raw in pageText.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty && line.count <= 120 {
                    payload.title = String(line)
                    break
                }
            }
        }

        // Render page 1 as a small PNG so the library tile has
        // something to show. We cap the longest edge so a 24 MP book
        // cover doesn't bloat UserDefaults; the JPEG-ish quality is
        // good enough for a 200pt thumbnail.
        if let firstPage = document.page(at: 0) {
            payload.cover = renderCover(page: firstPage, maxEdge: 600)
        }

        return payload
    }

    // MARK: - Helpers

    private static func stringValue(
        _ attrs: [AnyHashable: Any],
        key: String
    ) -> String? {
        if let raw = attrs[key] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Render `page` into a PNG `Data`. Scales the page bounds down so
    /// the longest edge equals `maxEdge` (points). We keep the math
    /// platform-neutral; the rasterisation differs between UIKit and
    /// AppKit.
    private static func renderCover(page: PDFPage, maxEdge: CGFloat) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale: CGFloat = {
            let longest = max(bounds.width, bounds.height)
            guard longest > maxEdge else { return 1.0 }
            return maxEdge / longest
        }()
        let target = CGSize(
            width: floor(bounds.width * scale),
            height: floor(bounds.height * scale)
        )
        return platformRender(page: page, size: target)
    }

    #if canImport(UIKit)
    private static func platformRender(page: PDFPage, size: CGSize) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.saveGState()
            // PDFs are PostScript-coordinated (origin at bottom-left).
            // UIKit's CGContext uses top-left, so flip vertically
            // before letting PDFKit draw.
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
            let bounds = page.bounds(for: .mediaBox)
            let scaleX = size.width / bounds.width
            let scaleY = size.height / bounds.height
            ctx.cgContext.scaleBy(x: scaleX, y: scaleY)
            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
        return image.pngData()
    }
    #elseif canImport(AppKit)
    private static func platformRender(page: PDFPage, size: CGSize) -> Data? {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scaleX = size.width / bounds.width
        let scaleY = size.height / bounds.height
        ctx.saveGState()
        ctx.scaleBy(x: scaleX, y: scaleY)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
    #else
    private static func platformRender(page: PDFPage, size: CGSize) -> Data? {
        return nil
    }
    #endif
}
