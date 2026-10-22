import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
enum EpubParagraphPresentation {
    static func applyStructuralParagraphStyles(
        to attr: NSMutableAttributedString,
        html: String,
        css: String,
        bodyFontSize: CGFloat
    ) {
        guard attr.length > 0 else { return }
        let source = html as NSString
        let blockRegex = try? NSRegularExpression(
            pattern: "(?is)<(p|h[1-6]|blockquote|li)\\b([^>]*)>"
        )
        let blockMatches = blockRegex?.matches(
            in: html,
            range: NSRange(location: 0, length: source.length)
        ) ?? []
        guard !blockMatches.isEmpty else { return }

        var paragraphRanges: [NSRange] = []
        var cursor = 0
        let rendered = attr.string as NSString
        while cursor < rendered.length {
            let range = rendered.paragraphRange(for: NSRange(location: cursor, length: 0))
            paragraphRanges.append(range)
            let next = NSMaxRange(range)
            cursor = next > cursor ? next : cursor + 1
        }

        for (index, match) in blockMatches.enumerated() where index < paragraphRanges.count {
            let tag = source.substring(with: match.range(at: 1)).lowercased()
            let attributes = source.substring(with: match.range(at: 2))
            let classes = classNames(in: attributes)
            let declarations = cssDeclarations(
                for: tag,
                classes: classes,
                css: css
            )
            let inline = cssDeclarations(from: inlineStyle(in: attributes))
            let merged = declarations.merging(inline) { _, inlineValue in inlineValue }
            guard merged["text-indent"] != nil || merged["margin-top"] != nil || merged["margin-bottom"] != nil else {
                continue
            }

            let range = paragraphRanges[index]
            let style = (attr.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            if let value = merged["text-indent"] {
                style.firstLineHeadIndent = cssLength(value, bodyFontSize: bodyFontSize)
            }
            if let value = merged["margin-top"] {
                style.paragraphSpacingBefore = cssLength(value, bodyFontSize: bodyFontSize)
            }
            if let value = merged["margin-bottom"] {
                style.paragraphSpacing = cssLength(value, bodyFontSize: bodyFontSize)
            }
            attr.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    private static func classNames(in attributes: String) -> [String] {
        guard let match = try? NSRegularExpression(pattern: "(?i)class\\s*=\\s*[\\\"']([^\\\"']+)")
            .firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length)),
              match.numberOfRanges > 1 else { return [] }
        let ns = attributes as NSString
        return ns.substring(with: match.range(at: 1))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    private static func inlineStyle(in attributes: String) -> String {
        guard let match = try? NSRegularExpression(pattern: "(?i)style\\s*=\\s*[\\\"']([^\\\"']+)")
            .firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length)),
              match.numberOfRanges > 1 else { return "" }
        return (attributes as NSString).substring(with: match.range(at: 1))
    }

    private static func cssDeclarations(for tag: String, classes: [String], css: String) -> [String: String] {
        let rules = try? NSRegularExpression(pattern: "(?s)([^{}]+)\\{([^{}]*)\\}")
        let ns = css as NSString
        var result: [String: String] = [:]
        for rule in rules?.matches(in: css, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let selectors = ns.substring(with: rule.range(at: 1)).lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let matches = selectors.contains { selector in
                selector == tag || classes.contains { className in
                    selector == ".\(className.lowercased())"
                        || selector.hasSuffix(" .\(className.lowercased())")
                        || selector.hasSuffix(">.\(className.lowercased())")
                }
            }
            if matches { result.merge(cssDeclarations(from: ns.substring(with: rule.range(at: 2)))) { _, new in new } }
        }
        return result
    }

    private static func cssDeclarations(from text: String) -> [String: String] {
        text.split(separator: ";").reduce(into: [:]) { result, item in
            let pair = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if pair.count == 2 { result[pair[0]] = pair[1] }
        }
    }

    private static func cssLength(_ raw: String, bodyFontSize: CGFloat) -> CGFloat {
        let pattern = "^\\s*([+-]?[0-9]*\\.?[0-9]+)\\s*(pt|px|em|rem|%)?"
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)),
              let number = Double((raw as NSString).substring(with: match.range(at: 1))) else { return 0 }
        let unit: String
        if match.numberOfRanges > 2 {
            let unitRange = match.range(at: 2)
            unit = unitRange.location != NSNotFound
                ? (raw as NSString).substring(with: unitRange).lowercased()
                : "pt"
        } else {
            unit = "pt"
        }
        switch unit {
        case "em", "rem": return CGFloat(number) * max(bodyFontSize, 16)
        case "px": return CGFloat(number) * 0.75
        case "%": return CGFloat(number) * max(bodyFontSize, 16) / 100
        default: return CGFloat(number)
        }
    }


}
