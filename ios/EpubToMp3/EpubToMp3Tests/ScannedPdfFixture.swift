import CoreGraphics
import CoreText
import Foundation

/// Synthetic PDFs whose pages carry selectable text or only a picture of text, like a scan.
enum ScannedPdfFixture {
    enum Page {
        case text(String)
        case image(String)
    }

    static func write(_ pages: [Page], to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let text):
                draw(text, size: 14, in: context, box: box)
            case .image(let text):
                guard let bitmap = CGContext(
                    data: nil, width: 1224, height: 1584, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584))
                bitmap.scaleBy(x: 2, y: 2)
                draw(text, size: 24, in: bitmap, box: box)
                guard let image = bitmap.makeImage() else { throw CocoaError(.fileWriteUnknown) }
                context.draw(image, in: box)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func draw(_ text: String, size: CGFloat, in context: CGContext, box: CGRect) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let setter = CTFramesetterCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        let path = CGPath(rect: box.insetBy(dx: 72, dy: 90), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
    }
}
