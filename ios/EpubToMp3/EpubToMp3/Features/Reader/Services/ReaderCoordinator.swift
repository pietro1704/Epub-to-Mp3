import Foundation
import Combine

/// Single source of truth for "where the user is reading right now".
///
/// Replaces the previous three-UserDefaults-keys IPC pattern
/// (`readerCurrentChapterIndex`, `readerCurrentPageRatio`,
/// `readerCurrentSentenceId`) with one in-process `ObservableObject`
/// injected via `@EnvironmentObject`. UserDefaults is still mirrored
/// 1:1 — but only via the coordinator, debounced — so the App Group
/// widget still has cross-process visibility without every page turn
/// kicking the prefs daemon three times.
///
/// Read sites: every play surface (mini player, full player,
/// PlayerView, PlayerReaderView, InstantReader transport) consults
/// `anchor.chapterIndex` to detect divergence vs the audio.
/// `PlayDivergenceAnchor.capture(readerChapterIndex:)` reads
/// `pageRatio` / `sentenceId` to scope its decision snapshot.
///
/// Write sites: `ReaderView.publishReadingRatio(pages:)` updates
/// `pageRatio` + `sentenceId` on every page change;
/// `InstantReaderView.compatOnChange(of: currentChapterIndex)` updates
/// `chapterIndex` and clears the position cursor.
@MainActor
final class ReaderCoordinator: ObservableObject {
    /// Immutable bundle of "where the reader is now". Replaces three
    /// separate UserDefaults reads with a single value-type snapshot.
    struct ReadingAnchor: Equatable, Sendable {
        /// EPUB zero-based chapter the user is viewing.
        let chapterIndex: Int
        /// 0…1 fraction into the chapter (paginated: cumulative char
        /// offset / total; scroll: contentOffset / contentSize).
        /// `nil` = unknown yet (chapter just opened).
        let pageRatio: Double?
        /// Id of the first sentence span on the current page, when
        /// the reader has timing data for it. `nil` = no anchor.
        let sentenceId: String?

        static let zero = ReadingAnchor(chapterIndex: 0, pageRatio: nil, sentenceId: nil)
    }

    @Published private(set) var anchor: ReadingAnchor = .zero

    /// UserDefaults mirror (App Group when available, standard
    /// otherwise) so widgets / extensions can still observe the
    /// reader position cross-process. Debounced through
    /// `mirrorTask` so a fast swipe-burst writes once at the end.
    private let defaults: UserDefaults
    private var mirrorTask: Task<Void, Never>?
    private var currentBookID: String?

    init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
        } else if let group = UserDefaults(suiteName: LibraryStore.appGroupID) {
            self.defaults = group
        } else {
            self.defaults = .standard
        }
        // Hydrate from the persisted snapshot so the first
        // `playTapDecision` after a cold launch already knows where
        // the user left off (the v0.5.6 flow seeded one
        // UserDefaults key from `InstantReaderView.onAppear`; we
        // preserve that contract).
        let chapter = self.defaults.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        let ratio = self.defaults.object(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey) as? Double
        let sentenceId = self.defaults.string(forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey)
        anchor = ReadingAnchor(chapterIndex: chapter, pageRatio: ratio, sentenceId: sentenceId)
    }

    func load(for bookID: String, fallbackChapterIndex: Int = 0) -> ReadingAnchor {
        currentBookID = bookID
        let prefix = "reader.position.v1.\(bookID)"
        let chapter = defaults.object(forKey: "\(prefix).chapter") as? Int ?? fallbackChapterIndex
        let ratio = defaults.object(forKey: "\(prefix).ratio") as? Double
        let sentenceId = defaults.string(forKey: "\(prefix).sentence")
        anchor = ReadingAnchor(chapterIndex: max(0, chapter), pageRatio: ratio, sentenceId: sentenceId)
        return anchor
    }

    private func namespacedKey(_ suffix: String) -> String? {
        guard let currentBookID else { return nil }
        return "reader.position.v1.\(currentBookID).\(suffix)"
    }

    /// Replace the entire anchor. Use for chapter changes (where
    /// page-cursor info from the previous chapter is stale).
    func setChapter(_ chapterIndex: Int) {
        anchor = ReadingAnchor(chapterIndex: chapterIndex, pageRatio: 0, sentenceId: nil)
        scheduleMirror()
    }

    /// Update the page cursor within the current chapter. Called by
    /// `ReaderView` on every settled page turn (already debounced
    /// on the writer side to once per 150 ms of input quiescence).
    func setPagePosition(ratio: Double, sentenceId: String?) {
        anchor = ReadingAnchor(
            chapterIndex: anchor.chapterIndex,
            pageRatio: ratio,
            sentenceId: sentenceId
        )
        scheduleMirror()
    }

    private func scheduleMirror() {
        mirrorTask?.cancel()
        let snapshot = anchor
        let defaults = self.defaults
        mirrorTask = Task { @MainActor in
            // Coalesce IPC: a chapter swap + a page-turn often arrive
            // in the same runloop tick. 150 ms is long enough to
            // batch them and short enough that widgets feel live.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            defaults.set(snapshot.chapterIndex, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
            if let key = self.namespacedKey("chapter") { defaults.set(snapshot.chapterIndex, forKey: key) }
            if let ratio = snapshot.pageRatio {
                defaults.set(ratio, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
                if let key = self.namespacedKey("ratio") { defaults.set(ratio, forKey: key) }
            } else {
                defaults.removeObject(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
                if let key = self.namespacedKey("ratio") { defaults.removeObject(forKey: key) }
            }
            if let id = snapshot.sentenceId {
                defaults.set(id, forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey)
                if let key = self.namespacedKey("sentence") { defaults.set(id, forKey: key) }
            } else {
                defaults.removeObject(forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey)
                if let key = self.namespacedKey("sentence") { defaults.removeObject(forKey: key) }
            }
        }
    }

    /// Flush any pending UserDefaults mirror immediately. Call from
    /// `onDisappear` so the App Group reflects the final position
    /// the moment the reader is torn down.
    func flush() {
        mirrorTask?.cancel()
        mirrorTask = nil
        let snapshot = anchor
        defaults.set(snapshot.chapterIndex, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        if let key = namespacedKey("chapter") { defaults.set(snapshot.chapterIndex, forKey: key) }
        // Mirror scheduleMirror's semantics: nil cursor REMOVES the key so a
        // stale sentenceId/pageRatio from a prior chapter never survives teardown.
        // Without this, cold-launch hydration could produce an anchor whose
        // sentenceId belongs to a different chapter than the persisted chapterIndex,
        // causing startFromReaderPage to sentence-seek into the wrong chapter.
        if let ratio = snapshot.pageRatio {
            defaults.set(ratio, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
            if let key = namespacedKey("ratio") { defaults.set(ratio, forKey: key) }
        } else {
            defaults.removeObject(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
            if let key = namespacedKey("ratio") { defaults.removeObject(forKey: key) }
        }
        if let id = snapshot.sentenceId {
            defaults.set(id, forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey)
            if let key = namespacedKey("sentence") { defaults.set(id, forKey: key) }
        } else {
            defaults.removeObject(forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey)
            if let key = namespacedKey("sentence") { defaults.removeObject(forKey: key) }
        }
    }
}
