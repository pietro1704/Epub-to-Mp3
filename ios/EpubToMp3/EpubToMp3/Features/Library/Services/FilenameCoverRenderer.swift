import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Draws that cover as a PNG: the file name in bold white, centred, on the book's colour.
enum FilenameCoverRenderer {
    private static let size = CGSize(width: 300, height: 450)
    private static let margin: CGFloat = 24
    private static let fontSize: CGFloat = 34
    private static let maximumLines: CGFloat = 4

    static func png(_ cover: FilenameCover) -> Data? {
        guard cover.backgroundRgb.count == 3,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let channels = cover.backgroundRgb.map { CGFloat($0) / 255 }
        context.setFillColor(red: channels[0], green: channels[1], blue: channels[2], alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        draw(cover.label, in: context)

        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func draw(_ label: String, in context: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeBytes(of: &alignment) { bytes in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: bytes.count, value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let text = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let width = size.width - margin * 2
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let limit = ceil(lineHeight * maximumLines) + 2
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                                                                  CGSize(width: width, height: limit), nil)
        let height = min(ceil(fitted.height) + 2, limit)
        let box = CGRect(x: margin, y: (size.height - height) / 2, width: width, height: height)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: box, transform: nil), nil), context)
    }
}
