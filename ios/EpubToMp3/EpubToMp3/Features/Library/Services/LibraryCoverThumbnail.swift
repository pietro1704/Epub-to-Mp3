import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum LibraryCoverThumbnail {
    // MARK: - Cover downsampling

    /// Maximum pixel dimensions for stored cover art. Widget surfaces
    /// render at ~200x300pt max, so anything larger wastes UserDefaults
    /// space. Downsampled covers use JPEG compression (0.7 quality) to
    /// stay under ~30-50 KB per book.
    private static let coverMaxWidth: CGFloat = 200
    private static let coverMaxHeight: CGFloat = 300
    /// JPEG quality factor. 0.7 gives a good balance between size and
    /// visual fidelity at thumbnail resolution.
    private static let coverJPEGQuality: CGFloat = 0.7
    /// Any cover blob larger than this threshold is considered oversized
    /// and will be downsampled. Prevents large PNG/JPEG data from
    /// bloating the shared UserDefaults (which has a ~4 MB practical
    /// limit across the App Group suite).
    static let coverMaxBytes = 80_000

    /// Downsample raw cover image data to fit within `coverMaxWidth` x
    /// `coverMaxHeight` and compress as JPEG. Returns the original data
    /// unchanged if it is already small enough.
    static func downsampleCover(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        // Already small enough — keep as-is.
        if data.count <= coverMaxBytes {
            return data
        }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return data }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return data }
        let scale = min(
            coverMaxWidth / size.width,
            coverMaxHeight / size.height,
            1.0 // never upscale
        )
        if scale >= 1.0 {
            // Image fits but is just stored in an uncompressed format.
            // Re-encode as JPEG to shrink it.
            return image.jpegData(compressionQuality: coverJPEGQuality) ?? data
        }
        let targetSize = CGSize(
            width: floor(size.width * scale),
            height: floor(size.height * scale)
        )
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: coverJPEGQuality) ?? data
        #else
        guard let image = NSImage(data: data) else { return data }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return data }
        let scale = min(
            coverMaxWidth / size.width,
            coverMaxHeight / size.height,
            1.0
        )
        let targetSize: CGSize
        if scale >= 1.0 {
            targetSize = size
        } else {
            targetSize = CGSize(
                width: floor(size.width * scale),
                height: floor(size.height * scale)
            )
        }
        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep = bitmapRep else { return data }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: CGRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: coverJPEGQuality]
        ) ?? data
        #endif
    }
}
