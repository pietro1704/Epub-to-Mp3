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
/// - `id` is computed as `String(index)` for SwiftUI list identity.
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
struct EbookFulltext: Codable, Equatable {

    /// One sentence-level segment with millisecond timestamps relative to
    /// the start of the chapter audio. Optional in the response; the
    /// current backend does not emit this field, but `SyncEngine` will
    /// prefer it over WPM estimation when present.
    struct Segment: Codable, Equatable, Hashable {
        let id: String?
        let text: String
        let startMs: Int?
        let endMs: Int?
    }

    struct Chapter: Codable, Equatable, Identifiable {
        let index: Int
        let name: String?
        let text: String
        let html: String?
        let css: String?
        let charCount: Int?
        let segments: [Segment]?

        var id: String { String(index) }

        var displayTitle: String {
            guard let name, !name.isEmpty else { return "Chapter \(index)" }
            return Self.cleanTitle(name)
        }

        private static func cleanTitle(_ raw: String) -> String {
            var result = raw
            // Insert space before uppercase run glued to lowercase: "parteI" → "parte I"
            result = result.replacingOccurrences(
                of: "([a-záàâãéèêíïóôõúüç])([A-ZÁÀÂÃÉÈÊÍÏÓÔÕÚÜÇ])",
                with: "$1 $2",
                options: .regularExpression
            )
            // Insert space before digit run glued to letters: "Chapter3" → "Chapter 3"
            result = result.replacingOccurrences(
                of: "([a-zA-Z])([0-9])",
                with: "$1 $2",
                options: .regularExpression
            )
            // Only Title-Case when the source is ALL-lowercase. If the
            // input is mixed-case ("parte I") or all-uppercase
            // ("PROLOGUE"), the publisher's casing carries semantic
            // intent — preserve it. Without this guard we'd lose every
            // case distinction (PROLOGUE → Prologue, parte I → Parte I).
            if result == result.lowercased() {
                result = result.capitalized
            }
            // Roman numerals are commonly disguised by `.capitalized`
            // (I → I, II → Ii). Restore them only when the source was
            // lowercased and capitalized — otherwise the publisher's
            // intent already preserved the right form.
            let romans = Set(["I","Ii","Iii","Iv","V","Vi","Vii","Viii","Ix","X",
                              "Xi","Xii","Xiii","Xiv","Xv","Xvi","Xvii","Xviii","Xix","Xx"])
            result = result.split(separator: " ").map { word in
                romans.contains(String(word)) ? String(word).uppercased() : String(word)
            }.joined(separator: " ")
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
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

    let jobId: String
    let bookTitle: String?
    let bookAuthor: String?
    let chapters: [Chapter]
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
