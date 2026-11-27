#if os(macOS)
import AppKit
import Combine
import PDFKit

/// READER-FOLLOW-NARRATION-MAC: while this reader's book is narrated, the reader scrolls (text) or turns (PDF) to the
/// spoken passage when it leaves the visible area, forward or backward. A scroll, key press, contents jump or PDF page
/// change the user makes suspends following until the narration is on screen again or the user moves the narration
/// (seek, skip, chapter). The rules live in `ReaderFollowNarration`; this class only reads the AppKit viewport.
@MainActor
final class MacReaderNarrationFollowing {
    private let document: MacReaderDocument
    private let composition: MacReaderViewComposition
    private let player: AudioPlayer
    private let settings: AppSettings
    private let showChapterIndex: (Int) -> Void
    private let isUserInput: () -> Bool
    private var observations: Set<AnyCancellable> = []
    private var isObserving = false
    private var goToNarrationTask: Task<Void, Never>?
    private lazy var follower = ReaderNarrationFollower(
        jumps: player.narrationJumps.eraseToAnyPublisher(),
        isNarrating: { [weak self] in
            guard let self, let bookID = self.document.currentBookId else { return false }
            return self.player.isPlaying && self.player.isPlaybackForReaderBook(bookID)
        },
        follow: { [weak self] in
            guard let self, self.settings.readerAutoScroll else { return }
            self.followNarration()
        })

    private var scrollView: NSScrollView { composition.contentScrollView }

    private lazy var highlight = ReaderAudioHighlightPresentation(
        player: player, settings: settings,
        surface: .init(
            bookID: { [weak self] in self?.document.currentBookId },
            chapter: { [weak self] in self.flatMap { $0.document.chapter(at: $0.document.selectedChapter) } },
            renderedText: { [weak self] in (self?.scrollView.documentView as? NSTextView)?.string },
            paint: { [weak self] sentence, word in
                guard let self else { return }
                MacNarrationPaint.apply(sentence: sentence, word: word, to: self.composition.textView)
            }))

    init(document: MacReaderDocument, composition: MacReaderViewComposition, player: AudioPlayer,
         settings: AppSettings, showChapterIndex: @escaping (Int) -> Void,
         isUserInput: @escaping () -> Bool = MacReaderNarrationFollowing.currentEventIsUserInput) {
        self.document = document
        self.isUserInput = isUserInput
        self.composition = composition
        self.player = player
        self.settings = settings
        self.showChapterIndex = showChapterIndex
    }

    var isSuspended: Bool { follower.isSuspended }

    /// "Go to reading": shows the spoken passage even while paused. A reader that was just opened waits for its
    /// saved position to be restored first, so the restore does not move it away again.
    func goToNarration() {
        follower.userAskedToGoToReading()
        goToNarrationTask?.cancel()
        goToNarrationTask = Task { [weak self] in
            for _ in 0..<100 {
                guard let self, !Task.isCancelled else { return }
                if self.document.hasRestoredInitialPosition, !self.document.isRestoringInitialPosition {
                    self.followNarration()
                    self.refresh()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func observe() {
        guard !isObserving else { return }
        isObserving = true
        player.readerPages = pageSource
        follower.start { [weak self] in self?.refresh() }
        highlight.observe()
        player.playbackClock.audioOutput.$position
            .throttle(for: .milliseconds(400), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observations)
        player.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &observations)
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: clip)
            .sink { [weak self] _ in self?.viewportMoved() }
            .store(in: &observations)
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewVisiblePagesChanged] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] note in
                    guard let self, let pdf = note.object as? MacReaderPDFView,
                          self.scrollView.documentView === pdf else { return }
                    self.viewportMoved()
                }
                .store(in: &observations)
        }
        refresh()
    }

    func stop() {
        goToNarrationTask?.cancel()
        observations.removeAll()
        follower.stop()
        highlight.stop()
        isObserving = false
        player.readerPairing.release(owner: ObjectIdentifier(self))
    }

    /// Publishes the pairing and follows the narration when it left the visible area.
    func refresh() {
        guard isObserving else { return }
        let paired = computePaired()
        player.readerPairing.publish(paired: paired, owner: ObjectIdentifier(self))
        follower.evaluate(paired: paired)
    }

    nonisolated static func currentEventIsUserInput() -> Bool {
        MainActor.assumeIsolated { isUserInput(NSApp.currentEvent) }
    }

    /// True for the events a person produces while moving the viewport (wheel, trackpad, scroller, keys, clicks).
    /// Layout, theme or PDFKit's own asynchronous updates run outside them and must not stop following.
    nonisolated static func isUserInput(_ event: NSEvent?) -> Bool {
        guard let type = event?.type else { return false }
        switch type {
        case .scrollWheel, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown, .keyUp,
             .magnify, .swipe, .smartMagnify, .rotate, .gesture, .beginGesture, .endGesture:
            return true
        default:
            return false
        }
    }

    /// The viewport moved. A move the reader did not make, caused by the user's input, while the narration is not on
    /// screen stops following.
    private func viewportMoved() {
        guard isObserving, !follower.isRevealing, document.hasRestoredInitialPosition,
              !document.isRestoringInitialPosition, isUserInput() else { return }
        if !computePaired() { follower.userTurnedThePage() }
        refresh()
    }

    // MARK: Page numbers

    private var pageSource: ReaderPageSource {
        ReaderPageSource(current: { [weak self] in self?.currentPageNumber() },
                         narrated: { [weak self] in self?.pageNumber(of: $0) })
    }

    private func currentPageNumber() -> Int? {
        if let pdf = scrollView.documentView as? MacReaderPDFView {
            return pdf.currentPage.flatMap { page in pdf.document.map { $0.index(for: page) + 1 } }
        }
        guard let text = scrollView.documentView as? NSTextView, let starts = pageStarts(in: text) else { return nil }
        return MacReaderTextLayout.pageIndex(of: scrollView.contentView.bounds.minY, in: starts) + 1
    }

    private func pageNumber(of location: ReaderPlaybackLocation) -> Int? {
        if let pdf = scrollView.documentView as? MacReaderPDFView { return spokenPage(location, in: pdf).map { $0 + 1 } }
        guard let text = scrollView.documentView as? NSTextView, let chapter = document.chapter(at: document.selectedChapter),
              chapter.zeroBasedEpubIndex == location.chapterIndex, let starts = pageStarts(in: text) else { return nil }
        let offset = location.characterOffset(chapterText: chapter.text, renderedText: text.string)
        guard offset >= 0, offset < text.string.utf16.count,
              let line = MacReaderTextLayout.lineRect(forCharacterAt: offset, in: text) else { return nil }
        return MacReaderTextLayout.pageIndex(of: line.minY, in: starts) + 1
    }

    // MARK: Pairing

    private func computePaired() -> Bool {
        guard let bookID = document.currentBookId, player.isPlaybackForReaderBook(bookID),
              let location = ReaderPlaybackLocation(player: player) else { return false }
        if let pdf = scrollView.documentView as? MacReaderPDFView { return isPaired(location, in: pdf) }
        guard let text = scrollView.documentView as? NSTextView, let chapter = document.chapter(at: document.selectedChapter),
              chapter.zeroBasedEpubIndex == location.chapterIndex else { return false }
        let offset = location.characterOffset(chapterText: chapter.text, renderedText: text.string)
        return ReaderNarrationPairing.isPaired(spokenChapter: location.chapterIndex, spokenOffset: offset,
                                               readerChapter: chapter.zeroBasedEpubIndex, visible: readableCharacterRange(in: text))
    }

    /// The visible characters without the lines a one-column page hides for the next page.
    private func readableCharacterRange(in text: NSTextView) -> NSRange? {
        let clip = scrollView.contentView
        guard let starts = pageStarts(in: text) else { return Self.visibleCharacterRange(in: text, clip: clip) }
        var rect = clip.documentVisibleRect
        let index = MacReaderTextLayout.pageIndex(of: rect.minY, in: starts)
        if abs(starts[index] - rect.minY) <= 1, index + 1 < starts.count {
            rect.size.height = max(1, min(rect.height, starts[index + 1] - rect.minY - 1))
        }
        return MacReaderTextLayout.characterRange(in: rect, of: text)
    }

    private func pageStarts(in text: NSTextView) -> [CGFloat]? {
        guard settings.readerLayout == .paginated, !MacReaderTextLayout.showsColumns(text) else { return nil }
        return MacReaderTextLayout.pageStarts(of: text, viewportHeight: scrollView.contentView.bounds.height)
    }

    private func isPaired(_ location: ReaderPlaybackLocation, in pdf: MacReaderPDFView) -> Bool {
        guard let spoken = spokenPage(location, in: pdf) else { return false }
        return ReaderNarrationPairing.isPaired(spokenPage: spoken, visiblePages: visiblePages(in: pdf))
    }

    private func spokenPage(_ location: ReaderPlaybackLocation, in pdf: MacReaderPDFView) -> Int? {
        guard let map = pdf.audioMap, map.chapters.indices.contains(location.chapterIndex) else { return nil }
        let text = map.chapters[location.chapterIndex].text
        let offset = location.characterOffset(chapterText: text, renderedText: text)
        return map.displayLocation(chapter: location.chapterIndex, character: offset)?.page
    }

    private func visiblePages(in pdf: MacReaderPDFView) -> [Int] {
        guard let document = pdf.document else { return [] }
        var pages = pdf.visiblePages.map { document.index(for: $0) }.filter { $0 != NSNotFound }
        if let current = pdf.currentPage { pages.append(document.index(for: current)) }
        return pages
    }

    static func visibleCharacterRange(in textView: NSTextView, clip: NSClipView) -> NSRange? {
        guard textView.textStorage?.length ?? 0 > 0, clip.bounds.height > 0 else { return nil }
        return MacReaderTextLayout.characterRange(in: clip.documentVisibleRect, of: textView)
    }

    // MARK: Following

    private func followNarration() {
        guard let location = ReaderPlaybackLocation(player: player) else { return }
        if let pdf = scrollView.documentView as? MacReaderPDFView {
            reveal(location, in: pdf)
        } else {
            revealText(location)
        }
    }

    private func reveal(_ location: ReaderPlaybackLocation, in pdf: MacReaderPDFView) {
        guard let pdfDocument = pdf.document, let page = spokenPage(location, in: pdf),
              let target = pdfDocument.page(at: page) else { return }
        pdf.go(to: target)
    }

    private func revealText(_ location: ReaderPlaybackLocation) {
        guard let chapters = document.fulltext?.chapters,
              let index = chapters.firstIndex(where: { $0.zeroBasedEpubIndex == location.chapterIndex }) else { return }
        if document.selectedChapter != index { showChapterIndex(index) }
        guard let text = scrollView.documentView as? NSTextView, let manager = text.layoutManager,
              text.string.utf16.count > 0 else { return }
        let offset = min(location.characterOffset(chapterText: chapters[index].text, renderedText: text.string),
                         text.string.utf16.count - 1)
        manager.textContainers.forEach { manager.ensureLayout(for: $0) }
        guard let line = MacReaderTextLayout.lineRect(forCharacterAt: offset, in: text) else { return }
        let clip = scrollView.contentView
        let lineY = line.minY
        let target = pageStarts(in: text).map { $0[MacReaderTextLayout.pageIndex(of: lineY, in: $0)] }
            ?? Self.scrollOffset(forLineAt: lineY, viewportHeight: clip.bounds.height,
                                 documentHeight: text.frame.height,
                                 paginated: settings.readerLayout == .paginated)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The scroll offset that shows the line at `lineY`: the start of the page that holds it.
    nonisolated static func scrollOffset(forLineAt lineY: CGFloat, viewportHeight: CGFloat,
                                         documentHeight: CGFloat, paginated: Bool) -> CGFloat {
        let maximum = max(0, documentHeight - viewportHeight)
        guard viewportHeight > 0 else { return 0 }
        let start = paginated ? (lineY / viewportHeight).rounded(.down) * viewportHeight : lineY - viewportHeight * 0.15
        return min(max(start, 0), maximum)
    }
}

/// Temporary layout attributes tint the narrated passage without touching the text storage, so saved
/// highlights, typography and the scroll position stay as they are.
@MainActor
private enum MacNarrationPaint {
    static func apply(sentence: NSRange?, word: NSRange?, to textView: NSTextView) {
        guard let manager = textView.layoutManager, let length = textView.textStorage?.length else { return }
        manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        for (range, alpha) in [(sentence, 0.20), (word, 0.65)] {
            guard let range, NSMaxRange(range) <= length else { continue }
            manager.addTemporaryAttribute(.backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(contrastSafeAlpha(alpha, at: range.location, in: textView)),
                forCharacterRange: range)
        }
    }

    private static func contrastSafeAlpha(_ preferred: Double, at location: Int, in textView: NSTextView) -> CGFloat {
        let text = (textView.textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor)
            ?? textView.textColor ?? .labelColor
        var components: (WCAGContrast.RGB?, WCAGContrast.RGB?, WCAGContrast.RGB?)
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            components = (text.srgbComponents, textView.backgroundColor.srgbComponents,
                          NSColor.systemYellow.srgbComponents)
        }
        guard let foreground = components.0, let background = components.1, let tint = components.2 else {
            return preferred
        }
        return ReaderHighlightContrast.alpha(preferred: preferred, tint: tint, text: foreground, background: background)
    }
}
#endif
