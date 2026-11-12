import Foundation

/// Maps a preview back to rendered UTF-16 coordinates, ignoring importer whitespace.
/// Ambiguous text never authorizes an arbitrary navigation destination.
enum ReaderAnchorRange {
    /// Resolve repeated words using the selected occurrence's surrounding text.
    static func sourceRange(rendered: String, selection: NSRange, in sourceText: String) -> NSRange? {
        guard selection.length > 0, Range(selection, in: rendered) != nil else { return nil }
        let startIndex = String.Index(utf16Offset: selection.location, in: rendered)
        let endIndex = String.Index(utf16Offset: NSMaxRange(selection), in: rendered)
        guard startIndex.samePosition(in: rendered.unicodeScalars) != nil,
              endIndex.samePosition(in: rendered.unicodeScalars) != nil else { return nil }
        let renderedText = normalized(rendered)
        let source = normalized(sourceText)
        guard let first = renderedText.offsets.firstIndex(where: { $0.upperBound > selection.location }),
              let last = renderedText.offsets.lastIndex(where: { $0.lowerBound < NSMaxRange(selection) }) else { return nil }
        let selected = first..<(last + 1)
        let renderedString = renderedText.text as NSString
        let sourceString = source.text as NSString
        for padding in [32, 128, 512, renderedText.offsets.count] {
            var lower = max(0, selected.lowerBound - padding)
            var upper = min(renderedText.offsets.count, selected.upperBound + padding)
            // Context boundaries must not split a surrogate pair.
            while lower > 0 && renderedText.offsets[lower] == renderedText.offsets[lower - 1] { lower -= 1 }
            while upper < renderedText.offsets.count && renderedText.offsets[upper] == renderedText.offsets[upper - 1] { upper += 1 }
            let context = renderedString.substring(with: NSRange(location: lower, length: upper - lower))
            let match = sourceString.range(of: context)
            guard match.location != NSNotFound else { continue }
            let remaining = NSRange(location: match.location + 1, length: sourceString.length - match.location - 1)
            guard sourceString.range(of: context, range: remaining).location == NSNotFound else { continue }
            let start = match.location + selected.lowerBound - lower
            let end = match.location + selected.upperBound - lower
            return NSRange(location: source.offsets[start].lowerBound,
                length: source.offsets[end - 1].upperBound - source.offsets[start].lowerBound)
        }
        return uniqueRange(preview: (rendered as NSString).substring(with: selection), in: sourceText)
    }

    static func uniqueRange(preview: String, in rendered: String) -> NSRange? {
        let target = normalized(preview).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = normalized(rendered)
        guard !target.isEmpty else { return nil }
        let range = (source.text as NSString).range(of: target)
        guard range.location != NSNotFound else { return nil }
        let remaining = NSRange(location: range.location + 1, length: (source.text as NSString).length - range.location - 1)
        guard (source.text as NSString).range(of: target, range: remaining).location == NSNotFound,
              range.location < source.offsets.count, NSMaxRange(range) <= source.offsets.count else { return nil }
        let start = source.offsets[range.location].lowerBound
        let end = source.offsets[NSMaxRange(range) - 1].upperBound
        return NSRange(location: start, length: end - start)
    }

    private static func normalized(_ text: String) -> (text: String, offsets: [Range<Int>]) {
        var result = ""
        var offsets: [Range<Int>] = []
        var utf16 = 0
        for scalar in text.unicodeScalars {
            let length = String(scalar).utf16.count
            let range = utf16..<(utf16 + length)
            utf16 += length
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if result.last == " " {
                    if let last = offsets.indices.last { offsets[last] = offsets[last].lowerBound..<range.upperBound }
                } else { result.append(" "); offsets.append(range) }
            } else {
                result.unicodeScalars.append(scalar)
                offsets.append(contentsOf: Array(repeating: range, count: length))
            }
        }
        return (result, offsets)
    }
}
