import Foundation

/// Maps a preview back to rendered UTF-16 coordinates, ignoring importer whitespace.
/// Ambiguous text never authorizes an arbitrary navigation destination.
enum ReaderAnchorRange {
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
