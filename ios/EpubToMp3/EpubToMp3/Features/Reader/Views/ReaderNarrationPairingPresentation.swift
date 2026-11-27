#if os(iOS)
import Combine
import UIKit

/// Publishes whether the visible page holds the narrated passage, so the expanded player can offer
/// "Go to reading" only when the reader and the narration have diverged. Read-only: it never moves the reader.
@MainActor
final class ReaderNarrationPairingPresentation {
    private let document: ReaderBookDocument
    private let player: AudioPlayer
    private let composition: ReaderViewComposition
    private var observations: Set<AnyCancellable> = []
    private var isObserving = false
    private let follower: ReaderNarrationFollower

    /// `reveal` moves the reader to the spoken passage (READER-FOLLOW-NARRATION).
    init(document: ReaderBookDocument, player: AudioPlayer, composition: ReaderViewComposition,
         reveal: @escaping (ReaderPlaybackLocation) -> Void) {
        self.document = document
        self.player = player
        self.composition = composition
        follower = ReaderNarrationFollower(player: player, bookID: document.book.id, reveal: reveal)
    }

    /// A page turn, scroll drag or chapter change made by the user: the reader stops following until the
    /// narration is on screen again or the user moves the narration.
    func userNavigated() { follower.userTurnedThePage() }

    func userAskedToGoToReading() { follower.userAskedToGoToReading() }

    func observe() {
        guard !isObserving else { return }
        isObserving = true
        player.readerPages = ReaderPageSource(current: { [weak self] in self?.currentPageNumber() },
                                              narrated: { [weak self] in self?.pageNumber(of: $0) })
        follower.start { [weak self] in self?.refresh() }
        player.playbackClock.audioOutput.$position
            .throttle(for: .milliseconds(400), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observations)
        player.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &observations)
        refresh()
    }

    func stop() {
        observations.removeAll()
        follower.stop()
        isObserving = false
        player.readerPairing.release(owner: ObjectIdentifier(self))
    }

    /// Call after anything that moves the viewport or changes the chapter.
    func refresh() {
        guard isObserving else { return }
        let paired = computePaired()
        player.readerPairing.publish(paired: paired, owner: ObjectIdentifier(self))
        follower.evaluate(paired: paired)
    }

    private func computePaired() -> Bool {
        guard player.isPlaybackForReaderBook(document.book.id),
              let chapter = currentChapter,
              let location = ReaderPlaybackLocation(player: player) else { return false }
        let textView = composition.textView
        let offset = location.chapterIndex == chapter.zeroBasedEpubIndex
            ? location.characterOffset(chapterText: chapter.text, renderedText: textView.text) : nil
        return ReaderNarrationPairing.isPaired(
            spokenChapter: location.chapterIndex, spokenOffset: offset,
            readerChapter: chapter.zeroBasedEpubIndex, visible: Self.visibleCharacterRange(in: textView, scrollView: composition.scrollView))
    }

    private func currentPageNumber() -> Int? {
        if composition.contentSurface.kind == .pdf { return composition.contentSurface.pdfPresentation?.currentPageNumber }
        guard composition.textViewport.numbersPages else { return nil }
        return composition.textViewport.pageNumber(at: composition.scrollView.contentOffset.y)
    }

    private func pageNumber(of location: ReaderPlaybackLocation) -> Int? {
        if composition.contentSurface.kind == .pdf { return composition.contentSurface.pdfPresentation?.pageNumber(of: location) }
        guard composition.textViewport.numbersPages, let chapter = currentChapter,
              location.chapterIndex == chapter.zeroBasedEpubIndex else { return nil }
        let textView = composition.textView
        let offset = location.characterOffset(chapterText: chapter.text, renderedText: textView.text)
        return composition.textViewport.pageNumber(containingCharacterAt: offset)
    }

    private var currentChapter: EbookFulltext.Chapter? {
        if let chapters = document.fulltext?.chapters, chapters.indices.contains(document.selectedChapter) {
            return chapters[document.selectedChapter]
        }
        return document.activePreparedChapter?.chapter
    }

    static func visibleCharacterRange(in textView: UITextView, scrollView: UIScrollView) -> NSRange? {
        guard textView.textStorage.length > 0, scrollView.bounds.height > 0 else { return nil }
        let manager = textView.layoutManager
        var rect = scrollView.convert(scrollView.bounds, to: textView)
        rect.origin.y -= textView.textContainerInset.top
        let glyphs = manager.glyphRange(forBoundingRect: rect, in: textView.textContainer)
        guard glyphs.length > 0 else { return nil }
        return manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }
}
#endif
