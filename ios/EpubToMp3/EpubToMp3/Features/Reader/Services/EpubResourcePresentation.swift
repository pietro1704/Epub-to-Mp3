import ImageIO
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if canImport(UIKit)
typealias EpubInlineImage = UIImage
#else
typealias EpubInlineImage = NSImage
#endif

@MainActor
enum EpubResourcePresentation {
    private static func stripImageSources(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"(<img\b[^>]*)\bsrc\s*=\s*("[^"]*"|'[^']*')"#,
            with: "$1",
            options: .regularExpression
        ).replacingOccurrences(
            of: #"(<image\b[^>]*)\bxlink:href\s*=\s*("[^"]*"|'[^']*')"#,
            with: "$1",
            options: .regularExpression
        )
    }

    /// Replace EPUB-relative image references with bounded, local data URIs.
    /// Resource hrefs are matched after percent-decoding and removing query/
    /// fragment suffixes; `data:` and remote URLs remain untouched.
    static func resolveResourceImageSources(
        _ html: String,
        resources: [EbookFulltext.Chapter.Resource]
    ) -> String {
        guard !resources.isEmpty else { return html }
        var byHref: [String: EbookFulltext.Chapter.Resource] = [:]
        for resource in resources {
            byHref[normalisedResourceHref(resource.href)] = resource
        }
        let pattern = try! NSRegularExpression(
            pattern: #"(?i)(<img\b[^>]*\bsrc\s*=\s*)([\"'])([^\"']+)(\2)"#
        )
        var result = html
        for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let srcRange = Range(match.range(at: 3), in: result) else { continue }
            let source = String(result[srcRange])
            guard !source.lowercased().hasPrefix("data:") else { continue }
            guard let resource = byHref[normalisedResourceHref(source)],
                  let encoded = resource.dataBase64,
                  let data = Data(base64Encoded: encoded),
                  !data.isEmpty else { continue }
            let mediaType = resource.mediaType ?? mimeType(for: source)
            let dataURI = "data:\(mediaType);base64,\(data.base64EncodedString())"
            result.replaceSubrange(srcRange, with: dataURI)
        }
        return result
    }

    private static func normalisedResourceHref(_ href: String) -> String {
        let withoutSuffix = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        let withoutQuery = withoutSuffix.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutSuffix
        return (withoutQuery.removingPercentEncoding ?? withoutQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func mimeType(for href: String) -> String {
        switch URL(fileURLWithPath: href).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// `NSAttributedString`'s HTML importer does not turn `<img>` tags
    /// into `.attachment` runs — it silently drops them. To keep inline
    /// EPUB images (already inlined as `data:` URIs by the caller) we
    /// swap each `<img src="data:...">` for a unique text placeholder
    /// before import, then splice a real `NSTextAttachment` back in at
    /// the placeholder's resolved range.
    static func extractDataURIImages(_ html: String) -> (String, [(token: String, image: EpubInlineImage)]) {
        var images: [(token: String, image: EpubInlineImage)] = []
        var result = ""
        var searchStart = html.startIndex
        var counter = 0

        while let match = html.range(
            of: #"<img\b[^>]*\bsrc\s*=\s*"data:image/[^;"]+;base64,[^"]*"[^>]*>"#,
            options: .regularExpression,
            range: searchStart..<html.endIndex
        ) {
            result += html[searchStart..<match.lowerBound]
            let tag = String(html[match])
            if let base64Range = tag.range(of: #"base64,[^"]*"#, options: .regularExpression) {
                let base64 = tag[base64Range].dropFirst("base64,".count)
                if let bytes = Data(base64Encoded: String(base64)),
                   let image = downsampledInlineImage(from: bytes) {
                    let token = "EPUBIMGPLACEHOLDER\(counter)EPUBIMGPLACEHOLDER"
                    counter += 1
                    images.append((token, image))
                    result += token
                } else {
                    // Undecodable payload — drop the tag rather than leak base64 text.
                }
            }
            searchStart = match.upperBound
        }
        result += html[searchStart..<html.endIndex]
        return (result, images)
    }

    /// Largest edge (in pixels) an inline EPUB image is decoded to.
    /// A paginated iPhone reader page is <=1290pt wide on the biggest
    /// device; 1400px covers @2x/@3x without over-allocating. The old
    /// path fed raw base64 bytes straight into `UIImage(data:)`, which
    /// decompresses to the FULL source resolution — a single 3000x3000
    /// EPUB illustration became a ~36 MB resident bitmap, and the
    /// scroll-mode buffer renders the current chapter plus both
    /// neighbours, so 3 image-heavy chapters could spike hundreds of MB
    /// on the main thread the instant the reader/player mounted. On an
    /// 8 GB device with the WidgetKit extension also being reloaded on
    /// the play burst, that memory storm is what forced a full device
    /// reboot (jetsam could not reclaim fast enough). Capping the decode
    /// here keeps each attachment bounded regardless of source size.
    private static let inlineImageMaxPixels = 1400

    /// Decode EPUB inline image bytes to a bitmap whose largest edge is
    /// at most `inlineImageMaxPixels`, using ImageIO's thumbnail path so
    /// the full-resolution bitmap is never allocated. Falls back to the
    /// plain decoder only when ImageIO cannot read the source (keeps
    /// exotic formats working), and that fallback is itself size-checked
    /// by the caller's format support — the common heavy case (large
    /// JPEG/PNG illustrations) always takes the bounded path.
    private static func downsampledInlineImage(from data: Data) -> EpubInlineImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return EpubInlineImage(data: data)
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: inlineImageMaxPixels,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
            return EpubInlineImage(data: data)
        }
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    static func inlineImageAttachments(
        _ images: [(token: String, image: EpubInlineImage)],
        into attr: NSMutableAttributedString
    ) {
        for (token, image) in images {
            let plain = attr.string as NSString
            let range = plain.range(of: token)
            guard range.location != NSNotFound else { continue }
            let attachment = NSTextAttachment()
            attachment.image = image
            attr.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
        }
    }

    /// Rewrite `@font-face src: url(...)` declarations to point at
    /// the local temp directory where `EpubFontManager` extracted the
    /// font files. When no font directory is available (fonts not
    /// registered), falls back to stripping the URLs entirely so the
    /// importer doesn't attempt to fetch unreachable EPUB-internal paths.
    static func rewriteFontFaceURLs(_ css: String, fontDirectory: URL?) -> String {
        guard let fontDir = fontDirectory else {
            // No fonts extracted — strip src declarations to avoid
            // the importer choking on relative EPUB paths.
            return css.replacingOccurrences(
                of: #"src:\s*url\([^)]*\)\s*;?"#,
                with: "",
                options: .regularExpression
            ).replacingOccurrences(
                of: #"@import\s+url\([^)]*\)\s*;?"#,
                with: "",
                options: .regularExpression
            )
        }

        let dirPath = fontDir.path
        // Rewrite each `src: url(...)` to a file:// URL pointing at
        // the extracted font file (filename only — EpubFontManager
        // flattens the EPUB's nested font paths into one directory).
        let srcPattern = try! NSRegularExpression(
            pattern: #"src:\s*url\(\s*['"]?([^'")]+)['"]?\s*\)"#
        )

        var result = css
        let matches = srcPattern.matches(
            in: css, range: NSRange(css.startIndex..., in: css)
        ).reversed()  // reverse so indices stay valid after mutation

        for match in matches {
            guard let wholeRange = Range(match.range, in: result),
                  let pathRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            let originalPath = String(result[pathRange])
            // Extract just the filename (last path component)
            let filename = (originalPath as NSString).lastPathComponent
            // Strip query strings / fragments from the filename
            let cleanFilename = filename.components(separatedBy: "?").first?
                .components(separatedBy: "#").first ?? filename
            let localURL = URL(fileURLWithPath: dirPath)
                .appendingPathComponent(cleanFilename)

            if FileManager.default.fileExists(atPath: localURL.path) {
                let replacement = "src: url('\(localURL.absoluteString)')"
                result.replaceSubrange(wholeRange, with: replacement)
            } else {
                // Font file not found in temp dir — strip the declaration
                // so the importer doesn't error on a missing file.
                result.replaceSubrange(wholeRange, with: "")
            }
        }

        // Still strip @import url(...) — those reference stylesheets,
        // not fonts, and won't resolve from the EPUB bundle.
        result = result.replacingOccurrences(
            of: #"@import\s+url\([^)]*\)\s*;?"#,
            with: "",
            options: .regularExpression
        )
        return result
    }
}
