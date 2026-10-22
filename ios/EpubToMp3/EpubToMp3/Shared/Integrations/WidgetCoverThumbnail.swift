import Foundation
import ImageIO

enum WidgetCoverThumbnail {
    /// Re-encode a stored cover blob to a small thumbnail via ImageIO so
    /// WidgetKit never holds a full-resolution decoded bitmap. Widget
    /// extensions are killed by `widgetkitd` at ~30 MB; covers are already
    /// downsampled to <=80 KB JPEG on the app side, but `UIImage(data:)`
    /// STILL decompresses to full pixel dimensions at render. Bounding the
    /// decode edge to `maximumPixels` keeps the render pass under
    /// the jetsam limit even when several widgets reload on a play burst.
    /// Returns the input untouched if ImageIO cannot read it.
    static let maximumPixels = 600

    static func make(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions) else {
            return data
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions),
              let out = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)
        else { return data }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return data }
        return out as Data
    }

}
