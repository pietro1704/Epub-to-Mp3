import Foundation

/// Mirrors the JSON contract emitted by `GET /api/jobs/{id}/fulltext`.
///
/// Source of truth: `python_app/server.py::get_job_fulltext` (around line 2769)
/// and `_build_fulltext_chapters_from_cache` (around line 2755).
///
/// ## Wire format
///
/// ```json
/// {
///   "jobId": "abc-123",
///   "bookTitle": "Foundation",
///   "bookAuthor": "Asimov",
///   "chapters": [
///     {"index": 1, "name": "Prologue", "text": "...",
///      "html": "<p>...</p>", "css": "...", "charCount": 1234}
///   ]
/// }
/// ```
///
/// ## Contract differences vs slice-3 brief
///
/// The brief assumed each chapter exposes `id` / `title` / optional
/// `segments[]`. The actual server payload uses **`index` + `name`** (no
/// stable string id, no per-sentence segment table). We map them here:
///
        /// - `id` is computed as `String(index)` for native list identity.
/// - `title` is the `name` field.
/// - `segments` is **not present in the response today** — `SyncEngine`
///   falls back to WPM estimation. Decoding `segments` is wired up so
///   that if the backend later adds `chapter.segments[]`, no model
///   change is needed.
///
/// The endpoint follows the retry contract documented in memory
/// `project_reader_fulltext.md`:
///
/// - 503 → transient (still extracting / source not yet on disk) → retry.
/// - 404 → permanent (job gone or terminal failed with no source).
/// - 422 → empty parse (parsed cleanly but produced zero chapters).
/// - 200 → chapters available.
struct EbookFulltext: Codable, Equatable, Sendable {

    /// One sentence-level segment with millisecond timestamps relative to
    /// the start of the chapter audio. Optional in the response; the
    /// current backend does not emit this field, but `SyncEngine` will
    /// prefer it over WPM estimation when present.
    struct Segment: Codable, Equatable, Hashable, Sendable {
        let id: String?
        let text: String
        let startMs: Int?
        let endMs: Int?
    }

    /// One footnote body extracted for a chapter — the same `{number,
    /// text}` pairs the speech pipeline already narrates inline. Used to
    /// power a native "Footnotes" sheet instead of trying to resolve a
    /// clickable in-document anchor (fragile: the reference can point at a
    /// separate notes file the sanitizer doesn't preserve cross-document).
    struct Footnote: Codable, Equatable, Hashable, Sendable {
        let number: String?
        let text: String
    }

    struct Chapter: Codable, Equatable, Identifiable, Sendable {
        struct Resource: Codable, Equatable, Hashable, Sendable {
            let href: String
            let mediaType: String?
            let dataBase64: String?
        }

        let index: Int
        let name: String?
        /// Zip-root-relative EPUB document path, retained so a reader can
        /// resolve a relative `<a href>` to the chapter that owns it.
        let sourcePath: String?
        let text: String
        /// Canonical parser-prepared payload for TTS. This is deliberately
        /// separate from reader-facing `text`, because it includes structural
        /// speech cues and may retain formatting markers until the conversion
        /// pipeline resolves them. Absent from older backend payloads.
        let speechText: String?
        let html: String?
        let css: String?
        let charCount: Int?
        let segments: [Segment]?
        let resources: [Resource]?
        let footnotes: [Footnote]?
        /// `"images"` for CBZ (one page image per chapter, `text` is
        /// intentionally empty); `"text"` (or absent, for older cached
        /// payloads) for every other format. Used to render an image page
        /// instead of text, and to disable TTS conversion for comics.
        let contentKind: String?

        var isImageOnly: Bool { contentKind == "images" }

        /// A cached chapter is usable only when it contains something the
        /// native reader can render (or an image page). This rejects stale
        /// parser caches that contain titles but no body payload.
        var hasReadableContent: Bool {
            if isImageOnly { return true }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }

        init(
            index: Int,
            name: String?,
            sourcePath: String? = nil,
            text: String,
            speechText: String? = nil,
            html: String?,
            css: String?,
            charCount: Int?,
            segments: [Segment]?,
            resources: [Resource]? = nil,
            footnotes: [Footnote]? = nil,
            contentKind: String? = nil
        ) {
            self.index = index
            self.name = name
            self.sourcePath = sourcePath
            self.text = text
            self.speechText = speechText
            self.html = html
            self.css = css
            self.charCount = charCount
            self.segments = segments
            self.resources = resources
            self.footnotes = footnotes
            self.contentKind = contentKind
        }

        var id: String { String(index) }

        /// Convert the backend's 1-based chapter index into the
        /// 0-based EPUB axis that `InstantReaderIndexMapper`,
        /// `WidgetDataSync`, and
        /// `cacheManager` all expect. Pre-slice-21 the search
        /// overlay handoff in the native reader skipped this
        /// conversion, so jumping to a search result wrote a
        /// 1-based value into a 0-based field and the player /
        /// widget / saved cursor all drifted by one chapter.
        var zeroBasedEpubIndex: Int { max(0, index - 1) }

        var displayTitle: String {
            if let heading = Self.firstHTMLHeading(in: html) {
                if let name, !name.isEmpty, !Self.isGeneratedChapterLabel(name) {
                    return name
                }
                return heading
            }
            if let name, Self.isGeneratedChapterLabel(name),
               let textHeading = Self.firstTextHeading(in: text) {
                return textHeading
            }
            if let name, !name.isEmpty { return name }
            return L10n.string("player.chapter", index)
        }

        var hasGeneratedName: Bool {
            guard let name, !name.isEmpty else { return true }
            return Self.isGeneratedChapterLabel(name)
        }

        var tocTitle: String? {
            let title = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return hasGeneratedName && Self.isGeneratedChapterLabel(title) ? nil : title
        }

        private static func isGeneratedChapterLabel(_ value: String) -> Bool {
            value.range(
                of: #"(?i)^\s*(chapter|cap[ií]tulo|chapitre|kapitel|capitolo)\s*\d+[\s.:\-]*$"#,
                options: .regularExpression
            ) != nil
        }

        private static func firstTextHeading(in text: String) -> String? {
            for line in text.components(separatedBy: .newlines) {
                let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty, candidate.count <= 160 else { continue }
                if candidate.range(of: #"(?i)^(chapter|cap[ií]tulo)\s+\d+[\s.:\-]*$"#, options: .regularExpression) == nil {
                    return candidate
                }
            }
            return nil
        }

        private static func firstHTMLHeading(in html: String?) -> String? {
            guard let html else { return nil }
            guard let match = html.range(
                of: #"(?is)<h[1-6][^>]*>.*?</h[1-6]>"#,
                options: .regularExpression
            ) else { return nil }
            let raw = String(html[match])
            let withoutTags = raw.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
            let decoded = withoutTags
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return decoded.isEmpty ? nil : decoded
        }

        /// Naive sentence splitter — breaks on `.`, `?`, `!` followed by
        /// whitespace. Good enough for highlight granularity; not
        /// publication-quality. Used when `segments` is absent.
        ///
        /// Returns `(id, text, startCharOffset, endCharOffset)` tuples.
        func splitSentences() -> [SentenceSpan] {
            let normalized = Self.stripLeadingArtifact(Self.collapseHardWraps(text))
            var spans: [SentenceSpan] = []
            let chars = Array(normalized)
            var start = 0
            var i = 0
            var sentenceIdx = 0

            while i < chars.count {
                let c = chars[i]
                let isTerminator = (c == "." || c == "?" || c == "!")
                let nextIsBoundary: Bool = {
                    guard i + 1 < chars.count else { return true }
                    let n = chars[i + 1]
                    return n == " " || n == "\t" || n == "\n" || n == "\r"
                }()

                if isTerminator && nextIsBoundary {
                    let endExclusive = i + 1
                    let raw = String(chars[start..<endExclusive])
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        spans.append(SentenceSpan(
                            id: "\(index):\(sentenceIdx)",
                            text: trimmed,
                            startChar: start,
                            endChar: endExclusive
                        ))
                        sentenceIdx += 1
                    }
                    var j = endExclusive
                    while j < chars.count && (chars[j] == " " || chars[j] == "\t" || chars[j] == "\n" || chars[j] == "\r") {
                        j += 1
                    }
                    start = j
                    i = j
                    continue
                }
                i += 1
            }
            if start < chars.count {
                let raw = String(chars[start..<chars.count])
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    spans.append(SentenceSpan(
                        id: "\(index):\(sentenceIdx)",
                        text: trimmed,
                        startChar: start,
                        endChar: chars.count
                    ))
                }
            }
            return spans
        }

        /// Strip EPUB artifact codes from the start of chapter text.
        /// These are file-level identifiers like "c34", "c4H7", "c60"
        /// that some EPUB converters embed as visible text.
        static func stripLeadingArtifact(_ text: String) -> String {
            let pattern = #"^[a-z][A-Z0-9][A-Za-z0-9]*\s*(\n|$)"#
            guard let range = text.range(of: pattern, options: .regularExpression) else {
                return text
            }
            var result = String(text[range.upperBound...])
            while result.hasPrefix("\n") { result.removeFirst() }
            return result
        }

        /// Join hard line-wraps (single `\n` mid-paragraph) into spaces.
        /// Preserves paragraph breaks (`\n\n`). Handles PDF-style column
        /// wrapping where words are split across lines ("f\ncado" → "ficado").
        static func collapseHardWraps(_ text: String) -> String {
            text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n\n", with: "\u{FFFE}")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\u{FFFE}", with: "\n\n")
        }
    }

    /// One TOC entry, hierarchy pre-resolved server-side (`chapterIndex`
    /// already points at the compacted `chapters[].index`, or `nil` when
    /// the href targets a dropped/empty chapter). The client never matches
    /// a raw href against a chapter path.
    struct TocEntry: Codable, Equatable, Sendable {
        let title: String
        let level: Int
        let chapterIndex: Int?
        let children: [TocEntry]
    }

    let jobId: String
    let bookTitle: String?
    let bookAuthor: String?
    let chapters: [Chapter]
    let toc: [TocEntry]?

    init(
        jobId: String,
        bookTitle: String?,
        bookAuthor: String?,
        chapters: [Chapter],
        toc: [TocEntry]? = nil
    ) {
        self.jobId = jobId
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.chapters = chapters
        self.toc = toc
    }
}

/// Sentence span produced either by `Chapter.splitSentences()` or by
/// projecting `EbookFulltext.Segment` onto character offsets. Used by
/// `SyncEngine` to build its lookup table and by `ReaderView` to render
/// individual `Text` rows with stable identity.
struct SentenceSpan: Equatable, Hashable, Identifiable {
    let id: String
    let text: String
    let startChar: Int
    let endChar: Int
}
