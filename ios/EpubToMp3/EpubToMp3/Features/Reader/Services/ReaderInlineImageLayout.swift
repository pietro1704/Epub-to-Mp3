import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Sizes inline EPUB image attachments to the reader's usable text width.
///
/// Returning `nil` means every attachment already has the required bounds,
/// allowing the caller to avoid replacing an entire attributed chapter during
/// a harmless layout pass.
enum ReaderInlineImageLayout {
    static func fitting(
        _ source: NSAttributedString,
        maximumWidth: CGFloat
    ) -> NSAttributedString? {
        guard source.length > 0, maximumWidth > 0 else { return nil }

        let fitted = NSMutableAttributedString(attributedString: source)
        var changed = false
        fitted.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: fitted.length)
        ) { value, _, _ in
            guard let attachment = value as? NSTextAttachment,
                  let image = attachment.image else {
                return
            }
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }

            let scale = min(1, maximumWidth / imageSize.width)
            let size = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
            guard attachment.bounds.size != size else { return }
            attachment.bounds = CGRect(origin: .zero, size: size)
            changed = true
        }

        return changed ? fitted : nil
    }
}
