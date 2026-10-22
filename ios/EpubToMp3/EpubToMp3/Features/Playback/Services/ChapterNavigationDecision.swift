import Foundation

/// Owns reader/playback divergence, canonical reader titles and anchor identity.
/// Decisions describe intent only; AudioPlayer alone changes the transport.
@MainActor
final class ChapterNavigationDecision {
    private var readerChapterTitles: [Int: String] = [:]
    var hasAnchor: Bool { readerPlaybackAnchor != nil }
    func clearAnchor() { readerPlaybackAnchor = nil }
    func clearTitles() { readerChapterTitles.removeAll() }
    private struct ReaderPlaybackAnchor {
        let bookID: String?
        let chapterIndex: Int
        let pageRatio: Double?
    }
    private var readerPlaybackAnchor: ReaderPlaybackAnchor?


    func isPlaybackForReaderBook(_ bookID: String) -> Bool {
        readerPlaybackAnchor?.bookID == bookID
    }

    func rememberReaderPlaybackAnchor() {
        let defaults = UserDefaults.standard
        guard let chapter = defaults.object(forKey: Self.readerCurrentChapterIndexDefaultsKey) as? Int else { return }
        readerPlaybackAnchor = ReaderPlaybackAnchor(
            bookID: defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
            chapterIndex: chapter,
            pageRatio: defaults.object(forKey: Self.readerCurrentPageRatioDefaultsKey) as? Double
        )
    }

    private func readerMovedFromPlaybackAnchor(chapterIndex: Int, pageRatio: Double?) -> Bool {
        guard let anchor = readerPlaybackAnchor else { return false }
        if anchor.bookID != UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
            || anchor.chapterIndex != chapterIndex { return true }
        guard let pageRatio, let previous = anchor.pageRatio else { return pageRatio != anchor.pageRatio }
        return abs(pageRatio - previous) > 0.001
    }

    func playTapDecision(
        readerChapterIndex: Int,
        readerPageRatio: Double? = nil, snapshot: JobSnapshot?, isPlaying: Bool,
        hasPausedPlaybackToResume: Bool, isSegmentMode: Bool, hasPlayer: Bool, currentChapterIndex: Int
    ) -> PlayTapDecision {
        if isPlaying { return .pause }
        guard let snapshot else { return .resume }
        if let bookID = readerPlaybackAnchor?.bookID,
           bookID != UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) {
            return .resume
        }
        if readerMovedFromPlaybackAnchor(chapterIndex: readerChapterIndex, pageRatio: readerPageRatio) {
            return .offerStartChoice
        }
        if hasPausedPlaybackToResume { return .resume }
        // Embedded-runtime path: chapters are fed through `enqueueSegment`
        // and the snapshot carries no `downloadUrl`s, so
        // `playableChapters` is permanently empty even though a live
        // AVQueuePlayer is loaded with audio. Without this short-circuit
        // every play tap returned `.offerStartChoice`; picking any
        // option then called `play(snapshot:)` which teardown the live
        // queue and refused to rebuild it (no URLs to build from) —
        // visible to the user as "asks to download but never plays".
        // When we're in segment mode with a live player, the divergence
        // dialog has nothing to resolve: just resume the existing queue.
        if isSegmentMode, hasPlayer { return .resume }
        // `readerChapterIndex` is the EPUB-zero-based chapter index
        // (the same space `fulltext.chapters[i].index - 1` lives in).
        // `currentChapterIndex` is an index into `playableChapters` —
        // the filtered subset. Compare in the *playable* space so
        // unplayable chapters between user and player (footnotes,
        // image-only sections) don't spuriously fire the dialog.
        //
        // When the reader sits BEFORE any playable chapter (e.g. the
        // book starts with a non-narratable preface and `playable[0]`
        // is EPUB index 5 while reader is at EPUB 0), there's no
        // matching playable for the reader — translation returns nil.
        // Treat that as divergent so the user gets the dialog instead
        // of a silent no-op.
        let reader = playableIndex(forEpubZeroBased: readerChapterIndex, in: snapshot)
        guard let reader else { return .offerStartChoice }
        // A concrete reader anchor is an explicit listener choice. It wins
        // even when the chapter matches the audio cursor, so tapping Play on
        // a later page never silently resumes an earlier passage.
        if reader == currentChapterIndex {
            return readerPageRatio == nil ? .resume : .startFromReaderPage
        }
        return .offerStartChoice
    }

    /// Convert an EPUB zero-based chapter index (what the reader views
    /// publish into UserDefaults) to the matching playable-list index
    /// (what `currentChapterIndex` lives in). Returns `nil` when no
    /// playable chapter is at or before `epubIndex` (the user is
    /// reading a preface that has no audio counterpart).
    ///
    /// Otherwise falls back to the last playable chapter whose EPUB
    /// index is ≤ the reader's, so a play tap from an unplayable
    /// chapter starts from the previous playable.

    func playableIndex(
        forEpubZeroBased epubIndex: Int,
        in snapshot: JobSnapshot
    ) -> Int? {
        let playable = snapshot.playableChapters
        guard !playable.isEmpty else { return nil }
        if let exact = playable.firstIndex(where: { $0.index == epubIndex }) {
            return exact
        }
        var fallback: Int?
        for (i, ch) in playable.enumerated() where ch.index <= epubIndex {
            fallback = i
        }
        return fallback
    }

    func effectiveTitle(snapshot: JobSnapshot?, playbackChapters: [JobSnapshot.Chapter],
                        currentChapterIndex: Int, isSegmentMode: Bool) -> String {
        // Before an audio queue exists, the compact player represents the
        // page the reader is showing, not the queue's default index zero.
        // This matters for books whose first readable EPUB entry is not the
        // first chapter the reader restores (for example, a table of contents
        // after an epigraph).
        if snapshot == nil,
           playbackChapters.isEmpty,
           let readerIndex = UserDefaults.standard.object(
               forKey: Self.readerCurrentChapterIndexDefaultsKey
           ) as? Int,
           let readerTitle = readerChapterTitles[readerIndex] {
            return Self.preferredChapterTitle(
                primary: readerTitle,
                secondary: nil,
                fallback: L10n.string("player.chapter", readerIndex + 1)
            )
        }
        if isSegmentMode {
            let streamedTitle = PlaybackSegmentSession.segmentChapterTitle(
                chapterIndex: currentChapterIndex,
                chapterProgress: snapshot?.chapterProgress ?? []
            )
            return Self.preferredChapterTitle(
                primary: streamedTitle,
                secondary: readerChapterTitles[currentChapterIndex],
                fallback: streamedTitle
            )
        }
        let chapters = playbackChapters.isEmpty ? (snapshot?.playableChapters ?? []) : playbackChapters
        guard chapters.indices.contains(currentChapterIndex) else {
            let pending = PlaybackSegmentSession.chapterProgressEntry(
                forSegmentIndex: currentChapterIndex,
                chapterProgress: snapshot?.chapterProgress ?? []
            )
            return Self.preferredChapterTitle(
                primary: pending?.name,
                secondary: readerChapterTitles[currentChapterIndex],
                fallback: pending?.displayTitle ?? L10n.string("player.chapter", currentChapterIndex + 1)
            )
        }
        let playing = chapters[currentChapterIndex]
        let progressName = snapshot?.chapterProgress?
            .first(where: { $0.index == playing.index })?.name
        // Reader fulltext indexes are zero-based while remote JobSnapshot
        // chapter indexes are one-based. Embedded snapshots use the former;
        // prefer the exact queue index and then the zero-based counterpart so
        // a real TOC title is not lost behind "Capítulo N".
        let readerName = readerChapterTitles[playing.index]
            ?? readerChapterTitles[playing.index - 1]
        return Self.preferredChapterTitle(
            primary: playing.name,
            secondary: readerName ?? progressName,
            fallback: playing.displayTitle
        )
    }


    func updateReaderChapterTitle(_ title: String, for index: Int) {
        guard !title.isEmpty else { return }
        readerChapterTitles[index] = title
    }

    func updateReaderChapterTitles(_ chapters: [EbookFulltext.Chapter]) -> Bool {
        var titles: [Int: String] = [:]
        for chapter in chapters {
            let title = chapter.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            titles[chapter.zeroBasedEpubIndex] = title
        }
        guard !titles.isEmpty else { return false }
        readerChapterTitles.merge(titles, uniquingKeysWith: { _, canonical in canonical })
        return true
    }

    nonisolated static func preferredChapterTitle(
        primary: String?,
        secondary: String?,
        fallback: String
    ) -> String {
        let candidates = [primary, secondary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isGenericChapterTitle($0) }
            .map { stripGenericChapterPrefix($0) }
        return candidates.first ?? fallback
    }

    nonisolated static func isGenericChapterTitle(_ title: String) -> Bool {
        let normalized = title.lowercased()
            .replacingOccurrences(of: "á", with: "a")
            .replacingOccurrences(of: "í", with: "i")
        if normalized == "chapter" || normalized == "capitulo" { return true }
        for prefix in ["chapter ", "capitulo "] {
            if normalized.hasPrefix(prefix), Int(normalized.dropFirst(prefix.count)) != nil {
                return true
            }
        }
        return false
    }

    /// Strips a leading "Chapter N: "/"Capítulo N: " label from an
    /// otherwise-substantive title (e.g. an EPUB TOC entry the backend
    /// prefixed with its own numbering) — unlike `isGenericChapterTitle`,
    /// which only rejects titles that are PURELY the generic label. Now
    /// Playing / lock-screen metadata should show "The Shadow of the
    /// Past", not "Chapter 2: The Shadow of the Past".

    private nonisolated static func stripGenericChapterPrefix(_ title: String) -> String {
        let normalized = title.lowercased()
            .replacingOccurrences(of: "á", with: "a")
            .replacingOccurrences(of: "í", with: "i")
        for prefix in ["chapter ", "capitulo "] {
            guard normalized.hasPrefix(prefix) else { continue }
            let afterPrefix = normalized[normalized.index(normalized.startIndex, offsetBy: prefix.count)...]
            guard let colonRange = afterPrefix.range(of: ": ") else { continue }
            let numberPart = afterPrefix[afterPrefix.startIndex..<colonRange.lowerBound]
            guard Int(numberPart) != nil else { continue }
            // `normalized` is a 1-char-for-1-char transform of `title`
            // (lowercasing + single-accented-letter substitution never
            // changes character count), so the same character offset
            // slices the ORIGINAL (non-lowercased) string correctly.
            let prefixCharCount = prefix.count + numberPart.count + 2 // + ": "
            let stripped = String(title.dropFirst(prefixCharCount))
            return stripped.isEmpty ? title : stripped
        }
        return title
    }

    // MARK: Play-tap routing (centralised so every UI surface — mini
    // player, full player, in-line buttons in the reader — uses the
    // same divergence detection / start-options behaviour. Adding a new
    // play button anywhere in the app should only require wiring
    // `playTapDecision(readerChapterIndex:readerPageRatio:)` + `startFromReaderPage(_:)`
    // + `startFromBeginning()` — never duplicate the conditional logic.)

    /// What an in-app play-button tap should do, given the chapter the
    /// reader is currently displaying. UI surfaces consult this and
    /// then either toggle, resume, or present the divergence dialog.
    /// Lock-screen / widget / remote-command paths bypass this entirely
    /// — they cannot show a dialog, so they hit `resume()` directly.
    enum PlayTapDecision {
        /// Audio is already playing — flip to pause.
        case pause
        /// No divergence (or no snapshot yet) — straight resume.
        case resume
        /// The reader exposed a concrete page anchor in the chapter that is
        /// already selected for audio. Start from that anchor rather than an
        /// older paused cursor.
        case startFromReaderPage
        /// Reader sits on a different chapter/page than the audio. The UI
        /// surface should show the start-position chooser
        /// (current page / where stopped).
        case offerStartChoice
    }

    /// Channel where the reader publishes the chapter the USER is
    /// currently reading (vs the chapter the audio is narrating). The
    /// mini-player / full-player compare these two indices on a play
    /// tap and, when they disagree, surface a three-option dialog so
    /// the user can choose what to start: current page, where they
    /// stopped, or the beginning.
    static let readerCurrentChapterIndexDefaultsKey = "readerCurrentChapterIndex"

    /// Companion channel — fraction (0.0 … 1.0) of how far into the
    /// current chapter the user has scrolled (paginated mode: page
    /// start char / total chars; scroll mode: contentOffset / contentSize).
    /// Read by `startFromReaderPage` so "From the current page"
    /// actually lands near the user's reading position instead of
    /// the chapter start. Stored as `Double` (UserDefaults does the
    /// `NSNumber` boxing).
    static let readerCurrentPageRatioDefaultsKey = "readerCurrentPageRatio"

    /// Companion channel — id of the first sentence on the user's
    /// currently-visible page. When the active chapter has timing
    /// data injected via `setSentenceTiming`, `startFromReaderPage`
    /// prefers this precise sentence anchor over the ratio
    /// approximation. Cleared on chapter change.
    static let readerCurrentSentenceIdDefaultsKey = "readerCurrentSentenceId"
}
