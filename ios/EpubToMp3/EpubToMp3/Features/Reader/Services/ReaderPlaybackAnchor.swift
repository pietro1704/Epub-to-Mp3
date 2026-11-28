import Foundation

/// Translates the reader's array position into the canonical zero-based EPUB
/// axis used by conversion, local artifacts, and playback. The two axes only
/// happen to match for simple books; front matter and sparse TOCs make them
/// diverge.
enum ReaderPlaybackAnchor {
    static func epubIndex(
        forReaderPosition position: Int,
        in chapters: [EbookFulltext.Chapter]
    ) -> Int? {
        guard chapters.indices.contains(position) else { return nil }
        return chapters[position].zeroBasedEpubIndex
    }

    /// Publishes the reader's live playback anchor in the EPUB chapter axis.
    /// The reader list can contain front matter and sparse TOC entries, while
    /// audio artifacts are always indexed by their original EPUB position.
    @MainActor
    @discardableResult
    static func publish(
        readerPosition: Int,
        chapters: [EbookFulltext.Chapter],
        offsetFraction: Double,
        defaults: UserDefaults = .standard
    ) -> Int? {
        guard let epubIndex = epubIndex(forReaderPosition: readerPosition, in: chapters) else {
            return nil
        }
        return publish(epubIndex: epubIndex, offsetFraction: offsetFraction, defaults: defaults)
    }

    @MainActor
    @discardableResult
    static func publish(chapter: EbookFulltext.Chapter, offsetFraction: Double,
                        defaults: UserDefaults = .standard) -> Int {
        publish(epubIndex: chapter.zeroBasedEpubIndex, offsetFraction: offsetFraction, defaults: defaults)
    }

    @MainActor
    private static func publish(epubIndex: Int, offsetFraction: Double, defaults: UserDefaults) -> Int {
        let location = ReaderLocation(defaults: defaults)
        location.setReaderAnchor(chapter: epubIndex, pageRatio: min(max(offsetFraction.isFinite ? offsetFraction : 0, 0), 1))
        return epubIndex
    }
}

/// Places the first text on screen on the narration source axis. The page is laid out from HTML,
/// so its character positions are not proportional to the narration text the core is given.
@MainActor
enum ReaderPageSourcePosition {
    private struct Index {
        let source: String
        /// The source without whitespace, and the source scalar behind each of its UTF-16 units.
        let compact: NSString
        let scalarOffsets: [Int]
        let scalarCount: Int
    }

    private static var cached: Index?
    private static let needleLengths = [40, 16]
    private static let attempts = 4

    /// The ratio that makes the core start at the text rendered at `character` (UTF-16).
    /// Nil when that text cannot be found in the source.
    static func ratio(renderedAt character: Int, in rendered: String, source: String) -> Double? {
        let index = index(for: source)
        let page = rendered as NSString
        guard index.scalarCount > 0, character >= 0, character < page.length else { return nil }
        // The proportional position only chooses between repeated passages.
        let estimate = Int(Double(character) / Double(page.length) * Double(index.compact.length))
        let window = page.substring(with: NSRange(location: character, length: min(600, page.length - character)))
        var visible = compacted(window).scalars
        for _ in 0..<attempts where !visible.isEmpty {
            for length in needleLengths {
                let needle = String(String.UnicodeScalarView(visible.prefix(length)))
                if let match = nearest(needle, in: index.compact, to: estimate) {
                    // The core floors ratio * length; one ULP up avoids the preceding scalar.
                    return (Double(index.scalarOffsets[match]) / Double(index.scalarCount)).nextUp
                }
            }
            visible = Array(visible.dropFirst(needleLengths[0]))
        }
        return nil
    }

    private static func nearest(_ needle: String, in text: NSString, to estimate: Int) -> Int? {
        let split = min(max(estimate, 0), text.length)
        let after = text.range(of: needle, options: .literal,
                               range: NSRange(location: split, length: text.length - split))
        let beforeEnd = min(text.length, split + needle.utf16.count)
        let before = text.range(of: needle, options: [.literal, .backwards],
                                range: NSRange(location: 0, length: beforeEnd))
        return [before.location, after.location].filter { $0 != NSNotFound }
            .min { abs($0 - estimate) < abs($1 - estimate) }
    }

    private static func index(for source: String) -> Index {
        if let cached, cached.source == source { return cached }
        let compact = compacted(source)
        var offsets: [Int] = []
        offsets.reserveCapacity(compact.scalars.count)
        for (scalar, offset) in zip(compact.scalars, compact.offsets) {
            offsets.append(contentsOf: repeatElement(offset, count: scalar.utf16.count))
        }
        let index = Index(source: source, compact: String(String.UnicodeScalarView(compact.scalars)) as NSString,
                          scalarOffsets: offsets, scalarCount: source.unicodeScalars.count)
        cached = index
        return index
    }

    private static func compacted(_ text: String) -> (scalars: [Unicode.Scalar], offsets: [Int]) {
        var scalars: [Unicode.Scalar] = [], offsets: [Int] = []
        for (offset, scalar) in text.unicodeScalars.enumerated()
        where !scalar.properties.isWhitespace && scalar != "\u{FFFC}" {
            scalars.append(scalar)
            offsets.append(offset)
        }
        return (scalars, offsets)
    }
}

/// Resolves the chapter that should be synthesized first when playback starts.
/// The live reader cursor wins for the book currently open on screen; saved
/// progress remains the fallback for starts initiated outside the reader.
@MainActor
enum ReaderPlaybackPriorityChapter {
    static func index(
        bookID: String,
        chapters: [EbookFulltext.Chapter]? = nil,
        defaults: UserDefaults = .standard
    ) -> Int {
        index(bookID: bookID, chapters: chapters, location: ReaderLocation(defaults: defaults), progressDefaults: defaults)
    }

    static func index(bookID: String, chapters: [EbookFulltext.Chapter]? = nil, location: ReaderLocation,
                      progressDefaults: UserDefaults = .standard) -> Int {
        if location.readingBookID == bookID, let liveIndex = location.readerChapter {
            return max(0, liveIndex)
        }

        guard let readerPosition = ReaderProgressStore.read(bookId: bookID, defaults: progressDefaults)?.chapterIndex else {
            return 0
        }
        let resolvedChapters = chapters ?? LocalFulltextCache.read(bookId: bookID)?.chapters ?? []
        return ReaderPlaybackAnchor.epubIndex(
            forReaderPosition: readerPosition,
            in: resolvedChapters
        ) ?? readerPosition
    }
}
