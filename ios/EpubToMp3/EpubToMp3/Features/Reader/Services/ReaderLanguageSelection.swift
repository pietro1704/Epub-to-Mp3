import Foundation

/// A correction uses Rust source scalars, never rendered UTF-16 coordinates.
enum ReaderLanguageSelection {
    static func passage(rendered: String, range: NSRange, source: String,
                        chapterIndex: Int) -> PassageLanguageCorrection? {
        guard let sourceRange = ReaderAnchorRange.sourceRange(rendered: rendered, selection: range, in: source),
              let resolved = Range(sourceRange, in: source) else { return nil }
        let start = source[..<resolved.lowerBound].unicodeScalars.count
        let end = start + source[resolved].unicodeScalars.count
        return .init(chapterIndex: chapterIndex, start: start, end: end, language: "")
    }
}

struct ReaderLanguageSelectionContext {
    let bookID: String
    let readerChapter: Int
    let scope: PassageLanguageCorrection
}
