import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Native archive work stays on MainActor; only immutable bytes cross to disk storage.
@MainActor
final class PreparedChapterRenderer {
    static let shared = PreparedChapterRenderer(store: PreparedChapterArchiveStore())
    private let store: PreparedChapterArchiveStore
    private let memory = NSCache<NSString, NSData>()
    private var writes: [UUID: Task<Void, Never>] = [:]

    init(store: PreparedChapterArchiveStore) {
        self.store = store
        memory.countLimit = 2
    }

    func cached(bookID: String, chapterIndex: Int, chapter: EbookFulltext.Chapter,
                settings: AppSettings, fontDirectoryURL: URL? = nil) -> NSAttributedString? {
        guard let signature = signature(chapter, settings, fontDirectoryURL) else { return nil }
        return cached(key: memoryKey(bookID, chapterIndex, signature))
    }

    func restore(bookID: String, chapterIndex: Int, chapter: EbookFulltext.Chapter,
                 settings: AppSettings, fontDirectoryURL: URL? = nil) async -> NSAttributedString? {
        guard let signature = signature(chapter, settings, fontDirectoryURL) else { return nil }
        let key = memoryKey(bookID, chapterIndex, signature)
        if let cached = cached(key: key) { return cached }
        guard let data = await store.read(bookID: bookID, chapterIndex: chapterIndex, signature: signature),
              self.signature(chapter, settings, fontDirectoryURL) == signature,
              let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data),
              decoded.length > 0 else { return nil }
        let immutable = NSAttributedString(attributedString: decoded)
        memory.setObject(data as NSData, forKey: key)
        return immutable
    }

    func render(bookID: String, chapterIndex: Int, chapter: EbookFulltext.Chapter,
                settings: AppSettings, fontDirectoryURL: URL? = nil) -> NSAttributedString? {
        let signature = signature(chapter, settings, fontDirectoryURL)
        if let signature, let cached = cached(key: memoryKey(bookID, chapterIndex, signature)) { return cached }
        guard let rendered = EpubHtmlRenderer.render(html: chapter.html ?? "", css: chapter.css,
                                                     settings: settings, fontDirectoryURL: fontDirectoryURL,
                                                     resources: chapter.resources) else { return nil }
        let immutable = canonicalRendering(NSAttributedString(rendered))
        // Cache encoding cannot turn a valid native render into plain-text fallback.
        guard let signature else { return immutable }
        let key = memoryKey(bookID, chapterIndex, signature)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: immutable, requiringSecureCoding: true) {
            // Each read decodes its own attachment/paragraph objects; views cannot
            // mutate a shared nested attribute through an immutable outer string.
            memory.setObject(data as NSData, forKey: key)
            let id = UUID()
            let store = self.store
            writes[id] = Task { @MainActor [weak self] in
                try? await store.write(data, bookID: bookID, chapterIndex: chapterIndex, signature: signature)
                self?.writes.removeValue(forKey: id)
            }
        }
        return immutable
    }

    func flush() async {
        let pending = Array(writes.values)
        for write in pending { await write.value }
    }

    private func canonicalRendering(_ text: NSAttributedString) -> NSAttributedString {
#if os(iOS)
        // UIKit color attributes require UIColor. The Foundation HTML bridge
        // can expose CGColor values, which keyed decoding converts implicitly.
        let result = NSMutableAttributedString(attributedString: text)
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB) else {
            return NSAttributedString(attributedString: text)
        }
        let keys: [NSAttributedString.Key] = [.foregroundColor, .backgroundColor, .strokeColor,
                                             .underlineColor, .strikethroughColor]
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            for key in keys {
                guard let value = attributes[key] else { continue }
                let color: CGColor
                if let native = value as? UIColor {
                    // Preserve adaptive system colors; canonicalize only fixed colors.
                    guard native.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).isEqual(
                        native.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))) else { continue }
                    color = native.cgColor
                } else {
                    guard CFGetTypeID(value as AnyObject) == CGColor.typeID else { continue }
                    color = value as! CGColor
                }
                guard let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
                      let components = converted.components, components.count == 4 else { continue }
                result.addAttribute(key, value: UIColor(red: components[0], green: components[1],
                    blue: components[2], alpha: components[3]), range: range)
            }
        }
        return NSAttributedString(attributedString: result)
#else
        return NSAttributedString(attributedString: text)
#endif
    }

    private func memoryKey(_ bookID: String, _ chapterIndex: Int, _ signature: String) -> NSString {
        "\(bookID.utf8.count):\(bookID):\(chapterIndex):\(signature)" as NSString
    }

    private func cached(key: NSString) -> NSAttributedString? {
        guard let data = memory.object(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data as Data)
    }

    private struct Signature: Encodable {
        let version = 2
        let chapter: EbookFulltext.Chapter
        let boldOverride: Bool
        let customColors: [Double]
        let fontFamily: String
        let letterSpacing: Double
        let lineSpacing: Double
        let overrideColours: Bool
        let overrideFontFamily: Bool
        let overrideFontSize: Bool
        let pointSize: Double
        let suppressItalic: Bool
        let textAlignment: String
        let theme: String
        let fontDirectory: String?
        let platform: String
        let operatingSystem: String
        let locale: String
        let languages: [String]
    }

    private func signature(_ chapter: EbookFulltext.Chapter, _ settings: AppSettings,
                           _ fontDirectory: URL?) -> String? {
        let colors = settings.readerCustomColors
#if os(iOS)
        let platform = "iOS:\(UIApplication.shared.preferredContentSizeCategory.rawValue)"
#else
        let platform = "macOS"
#endif
        let payload = Signature(chapter: chapter, boldOverride: settings.readerBoldOverride,
                                customColors: [colors.background.0, colors.background.1, colors.background.2,
                                               colors.foreground.0, colors.foreground.1, colors.foreground.2],
                                fontFamily: settings.readerFontFamily.rawValue,
                                letterSpacing: settings.readerLetterSpacing, lineSpacing: Double(settings.readerLineSpacing),
                                overrideColours: settings.readerOverrideColours,
                                overrideFontFamily: settings.readerOverrideFontFamily,
                                overrideFontSize: settings.readerOverrideFontSize, pointSize: Double(settings.readerPointSize),
                                suppressItalic: settings.readerSuppressItalic,
                                textAlignment: settings.readerTextAlignment.rawValue, theme: settings.readerTheme.rawValue,
                                fontDirectory: fontDirectory?.standardizedFileURL.absoluteString,
                                platform: platform, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                locale: Locale.current.identifier, languages: Locale.preferredLanguages)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
