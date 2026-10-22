import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
@testable import EpubToMp3

extension EpubHtmlRendererTests {
    @MainActor
    func testPreservesInlineDataURIImages() {
        let s = makeSettings()
        // Full valid 1x1 transparent GIF (header + image data + trailer) — a
        // truncated header-only payload is not decodable by UIImage/NSImage.
        let html = "<p>text</p><img src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEKAAAALAAAAAABAAEAAAICTAEAOw==\" alt=\"pixel\"/>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil for HTML with inline image")
        }
        let n = ns(out)
        var attachmentCount = 0
        n.enumerateAttribute(.attachment, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if value != nil { attachmentCount += 1 }
        }
        XCTAssertGreaterThan(attachmentCount, 0,
            "inline data: URI images must survive HTML sanitisation so the importer can create attachments")
    }

    @MainActor
    func testResolvesRelativeAndPercentEncodedImageResources() {
        let s = makeSettings()
        let resource = EbookFulltext.Chapter.Resource(
            href: "../images/cover%20art.png",
            mediaType: "image/png",
            dataBase64: "R0lGODlhAQABAIAAAAAAAP///yH5BAEKAAAALAAAAAABAAEAAAICTAEAOw=="
        )
        let html = "<p>text</p><img src=\"../images/cover%20art.png\"/>"
        guard let out = EpubHtmlRenderer.render(
            html: html, css: nil, settings: s, resources: [resource]
        ) else { return XCTFail("renderer returned nil") }
        let n = ns(out)
        var attachmentCount = 0
        n.enumerateAttribute(.attachment, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if value != nil { attachmentCount += 1 }
        }
        XCTAssertEqual(attachmentCount, 1)
    }

    @MainActor
    func testPreservesFragmentAndRelativeEPUBLinksForNativeRouting() {
        let s = makeSettings()
        let html = "<p><a href=\"#footnote_1\">*</a> <a href=\"chapter-2.xhtml#part\">Chapter Two</a></p>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        var targets: [String] = []
        n.enumerateAttribute(.link, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if let url = value as? URL {
                targets.append(url.absoluteString)
            } else if let url = value as? NSURL {
                targets.append((url as URL).absoluteString)
            }
        }

        XCTAssertEqual(targets.count, 2)
        let decodedTargets = targets.compactMap { URLComponents(string: $0)?
            .queryItems?
            .first(where: { $0.name == "target" })?
            .value
        }
        XCTAssertEqual(Set(decodedTargets), Set(["#footnote_1", "chapter-2.xhtml#part"]))
        XCTAssertTrue(targets.allSatisfy { $0.hasPrefix("epub-link://open?") })
    }

    @MainActor
    func testLargeInlineImageIsDownsampled() throws {
        let s = makeSettings()
        let bigPNG = try Self.makeSolidPNGBase64(width: 2000, height: 2000)
        let html = "<p>text</p><img src=\"data:image/png;base64,\(bigPNG)\" alt=\"big\"/>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil for HTML with large inline image")
        }
        let n = ns(out)
        var maxEdge: CGFloat = 0
        n.enumerateAttribute(.attachment, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            #if canImport(AppKit)
            guard let att = value as? NSTextAttachment, let img = att.image else { return }
            // NSImage.size is in points; the cgImage carries true pixels.
            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                maxEdge = max(maxEdge, CGFloat(max(cg.width, cg.height)))
            }
            #endif
        }
        #if canImport(AppKit)
        XCTAssertGreaterThan(maxEdge, 0, "expected a decoded attachment image")
        XCTAssertLessThanOrEqual(
            maxEdge, 1400,
            "inline image must be capped at 1400px; got \(maxEdge)px — full-res decode reintroduces the OOM device-freeze"
        )
        #endif
    }

    /// Build a base64-encoded solid-colour PNG of the given pixel size for
    /// exercising the inline-image downsample path.
    private static func makeSolidPNGBase64(width: Int, height: Int) throws -> String {
        #if canImport(AppKit)
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("could not build PNG fixture")
        }
        return png.base64EncodedString()
        #else
        throw XCTSkip("PNG fixture only built on AppKit host")
        #endif
    }

}
