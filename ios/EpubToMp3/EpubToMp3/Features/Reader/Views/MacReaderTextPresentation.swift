#if os(macOS)
import AppKit
import PDFKit
import Combine

/// Owns Mac chapter mounting and saved-position restoration after committed layout.
@MainActor
final class MacReaderTextPresentation {
    private let location: ReaderLocation
    private let document: MacReaderDocument
    private let composition: MacReaderViewComposition
    private let settings: AppSettings
    private let preparedRenderer: PreparedChapterRenderer
    private let initialPositionScheduler: (@escaping @MainActor () -> Void) -> Void
    private let reducesMotion: () -> Bool
    private let repaintSavedHighlights: (Int) -> Void
    private let prepareChapterProjection: (String, Int) -> Void
    private let selectCurrentTOCRow: () -> Void
    private let closeReader: () -> Void
    private let observeOpenStage: (String) -> Void
    private var settingsCancellables: Set<AnyCancellable> = []
    var onPlayPDF: ((PDFReadingAudioMap.Anchor) -> Void)?
    private var pageIndicator: NSTextField { composition.pageIndicator }
    private var textView: MacReaderTextView { composition.textView }
    private var comicPageImageView: NSImageView { composition.comicPageImageView }
    private var contentScrollView: NSScrollView { composition.contentScrollView }
    private var toolbar: NSStackView { composition.toolbar }
    private var bookTitleLabel: NSTextField { composition.bookTitleLabel }
    private var chapterTitleLabel: NSTextField { composition.chapterTitleLabel }
    private var statusLabel: NSTextField { composition.statusLabel }
    private var view: NSView { composition.view }
    private var loadGeneration: UUID {
        get { document.loadGeneration }
        set { document.loadGeneration = newValue }
    }
    private var presentationGeneration: UUID {
        get { document.presentationGeneration }
        set { document.presentationGeneration = newValue }
    }
    private var activeBookOpenJourneyID: UUID? { document.openJourney.activeBookOpenJourneyID }
    private var fulltext: EbookFulltext? {
        get { document.fulltext }
        set { document.fulltext = newValue }
    }
    private var activePreparedChapter: PreparedReaderChapterStore.Snapshot? {
        get { document.activePreparedChapter }
        set { document.activePreparedChapter = newValue }
    }
    private var selectedChapter: Int {
        get { document.selectedChapter }
        set { document.selectedChapter = newValue }
    }
    private var currentBookId: String? {
        get { document.currentBookId }
        set { document.currentBookId = newValue }
    }
    private var hasRestoredInitialPosition: Bool {
        get { document.hasRestoredInitialPosition }
        set { document.hasRestoredInitialPosition = newValue }
    }
    private var isRestoringInitialPosition: Bool {
        get { document.isRestoringInitialPosition }
        set { document.isRestoringInitialPosition = newValue }
    }
    private var pendingAppearanceRefresh: Bool {
        get { document.pendingAppearanceRefresh }
        set { document.pendingAppearanceRefresh = newValue }
    }

    init(document: MacReaderDocument, composition: MacReaderViewComposition, settings: AppSettings, location: ReaderLocation,
         renderer: PreparedChapterRenderer,
         initialPositionScheduler: @escaping (@escaping @MainActor () -> Void) -> Void,
         stageObserver: (@Sendable (String, UInt64) -> Void)?, reducesMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         repaintSavedHighlights: @escaping (Int) -> Void,
         prepareChapterProjection: @escaping (String, Int) -> Void, selectCurrentTOCRow: @escaping () -> Void,
         closeReader: @escaping () -> Void) {
        self.location = location
        self.document = document
        self.composition = composition
        self.settings = settings
        preparedRenderer = renderer
        self.initialPositionScheduler = initialPositionScheduler
        self.reducesMotion = reducesMotion
        self.repaintSavedHighlights = repaintSavedHighlights
        self.prepareChapterProjection = prepareChapterProjection
        self.selectCurrentTOCRow = selectCurrentTOCRow
        self.closeReader = closeReader
        observeOpenStage = { stageObserver?($0, DispatchTime.now().uptimeNanoseconds) }
    }

    private func isActiveLoad(_ id: UUID, bookID: String) -> Bool { document.isActiveLoad(id, bookID: bookID) }

    func observeAppearance() {
        // Scrolling, page turns and window resizes all move or resize the viewport.
        contentScrollView.contentView.postsBoundsChangedNotifications = true
        contentScrollView.contentView.postsFrameChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        let moves: [(Notification.Name, NSView)] = [
            (NSView.boundsDidChangeNotification, contentScrollView.contentView),
            (NSView.frameDidChangeNotification, contentScrollView.contentView),
            (NSView.frameDidChangeNotification, textView),
        ]
        for (name, source) in moves {
            NotificationCenter.default.publisher(for: name, object: source)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updatePageIndicator() }
                .store(in: &settingsCancellables)
        }
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.chapter(at: self.selectedChapter) != nil else { return }
                if self.isRestoringInitialPosition {
                    self.pendingAppearanceRefresh = true
                    return
                }
                // @Published emits before mutation. The queued delivery above
                // reads the committed settings and preserves the exact viewport
                // while regenerating authored colors when returning to light.
                let origin = self.contentScrollView.contentView.bounds.origin
                self.applyCurrentReaderTheme()
                self.showChapter(self.selectedChapter)
                // A new column count can shorten the document.
                let maximumY = max(0, (self.contentScrollView.documentView?.frame.height ?? 0)
                    - self.contentScrollView.contentView.bounds.height)
                self.contentScrollView.contentView.scroll(to: NSPoint(x: origin.x, y: min(origin.y, maximumY)))
                self.contentScrollView.reflectScrolledClipView(self.contentScrollView.contentView)
                self.persistReadingProgress()
            }
            .store(in: &settingsCancellables)
    }

    func applyCurrentReaderTheme() {
        MacReaderTheme.apply(
            textSettings: ReaderTextSettings(settings: settings),
            surface: view,
            scrollView: contentScrollView,
            textView: textView,
            toolbar: toolbar,
            labels: [bookTitleLabel, chapterTitleLabel, statusLabel]
        )
    }

    func restoreSelectedChapter(bookID: String) async {
        guard let chapter = chapter(at: selectedChapter), !chapter.isImageOnly else { return }
        observeOpenStage("selected_chapter_restore_started")
        _ = await preparedRenderer.restore(bookID: bookID, chapterIndex: selectedChapter,
                                           chapter: chapter, currentTextSettings: { ReaderTextSettings(settings: self.settings) },
                                           fontDirectoryURL: document.fontDirectoryURL)
        observeOpenStage("selected_chapter_restore_completed")
    }

    func showChapter(_ index: Int, scrollToEnd: Bool = false) {
        guard let chapter = chapter(at: index) else { return }
        presentationGeneration = UUID()
        chapterTitleLabel.stringValue = chapter.name ?? ""

        composition.setPageIndicatorShown(!chapter.isImageOnly && settings.readerLayout == .paginated && settings.readerShowPageNumbers)
        view.layoutSubtreeIfNeeded()
        pageIndicator.textColor = settings.readerColors.foreground

        if chapter.isImageOnly {
            if let base64 = chapter.resources?.first?.dataBase64, let data = Data(base64Encoded: base64) {
                comicPageImageView.image = NSImage(data: data)
            } else {
                comicPageImageView.image = nil
            }
            comicPageImageView.imageScaling = .scaleProportionallyUpOrDown
            contentScrollView.documentView = comicPageImageView
        } else {
            contentScrollView.documentView = textView
            if let bookID = currentBookId,
               let rendered = preparedRenderer.render(
                   bookID: bookID, chapterIndex: index, chapter: chapter,
                   textSettings: ReaderTextSettings(settings: settings), fontDirectoryURL: document.fontDirectoryURL
               ) {
                textView.textStorage?.setAttributedString(NSAttributedString(attributedString: rendered))
            } else {
                textView.string = chapter.text
                textView.font = ReaderFontCatalog.font(for: settings.readerOverrideFontFamily ? settings.readerFontFamily : .original, size: settings.readerPointSize)
                textView.textColor = settings.readerColors.foreground
            }
            MacReaderTextLayout.fit(textView, in: contentScrollView, columns: settings.readerColumns)
            repaintSavedHighlights(index)
            // NSTextView's responder actions need not move this read-only
            // viewport. Commit its measured destination directly.
            let clipView = contentScrollView.contentView
            let end = max(0, textView.frame.height - clipView.bounds.height)
            clipView.scroll(to: NSPoint(x: 0, y: scrollToEnd ? end : 0))
            contentScrollView.reflectScrolledClipView(clipView)
        }
        updatePageIndicator()
        composition.setFootnotesAvailable(chapter.footnotes?.isEmpty == false)
        ReaderPlaybackAnchor.publish(chapter: chapter, offsetFraction: 0, defaults: location.defaults)
        if let bookID = currentBookId { prepareChapterProjection(bookID, index) }
    }

    private func chapter(at ordinal: Int) -> EbookFulltext.Chapter? { document.chapter(at: ordinal) }

    func handleKeyboardEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 124, 125, 49:
            scrollPage(forward: true)
            return true
        case 123, 126:
            scrollPage(forward: false)
            return true
        case 53:
            closeReader()
            return true
        default:
            return false
        }
    }

    func scrollPage(forward: Bool) {
        guard activeBookOpenJourneyID == nil, !isRestoringInitialPosition else { return }
        guard let documentView = contentScrollView.documentView else { return }
        contentScrollView.layoutSubtreeIfNeeded()
        let clipView = contentScrollView.contentView
        let visibleBounds = clipView.bounds
        let columnar = (documentView as? NSTextView).map(MacReaderTextLayout.showsColumns) ?? false
        let page = Self.pageStep(viewportHeight: visibleBounds.height, columnar: columnar)
        let maximumY = max(0, documentView.frame.height - visibleBounds.height)
        let atStart = visibleBounds.origin.y <= 1
        let atEnd: Bool
        if !columnar, let readerTextView = documentView as? NSTextView,
           let container = readerTextView.textContainer,
           let layoutManager = readerTextView.layoutManager {
            layoutManager.ensureLayout(for: container)
            let lastGlyphBottom = layoutManager.usedRect(for: container).maxY
            atEnd = clipView.documentVisibleRect.maxY >= lastGlyphBottom
        } else {
            atEnd = visibleBounds.origin.y >= maximumY - 1
        }
        if forward && atEnd, selectedChapter + 1 < (fulltext?.chapters.count ?? 0) {
            persistReadingProgress()
            selectedChapter += 1
            showChapter(selectedChapter)
            selectCurrentTOCRow()
            persistReadingProgress()
            return
        }
        if !forward && atStart, selectedChapter > 0 {
            persistReadingProgress()
            selectedChapter -= 1
            showChapter(selectedChapter, scrollToEnd: true)
            selectCurrentTOCRow()
            persistReadingProgress()
            return
        }
        let offset = forward ? page : -page
        let nextY = min(max(visibleBounds.origin.y + offset, 0), maximumY)
        clipView.scroll(to: NSPoint(x: visibleBounds.origin.x, y: nextY))
        contentScrollView.reflectScrolledClipView(clipView)
        persistReadingProgress()
    }

    // MARK: - Pagination (viewport snap) + progress restoration

    /// Column pages are exact viewport pages; one column keeps an overlap.
    private static func pageStep(viewportHeight: CGFloat, columnar: Bool) -> CGFloat {
        max(1, viewportHeight * (columnar ? 1 : 0.9))
    }

    /// Numbers pages by the same step a page turn moves, ending where the text ends.
    func updatePageIndicator() {
        guard !pageIndicator.isHidden, contentScrollView.documentView === textView,
              let container = textView.textContainer, let manager = textView.layoutManager else { return }
        let bounds = contentScrollView.contentView.bounds
        let columnar = MacReaderTextLayout.showsColumns(textView)
        let step = Self.pageStep(viewportHeight: bounds.height, columnar: columnar)
        var end = max(0, textView.frame.height - bounds.height)
        if !columnar {
            manager.ensureLayout(for: container)
            let textBottom = manager.usedRect(for: container).maxY + textView.textContainerOrigin.y
            end = min(end, max(0, textBottom - bounds.height))
        }
        let total = max(0, Int(((end - 1) / step).rounded(.up))) + 1
        let page = bounds.origin.y >= end - 1 ? total
            : min(total, max(1, Int((bounds.origin.y / step).rounded()) + 1))
        let value = L10n.string("reader.pageOf", page, total)
        if pageIndicator.stringValue != value { pageIndicator.stringValue = value }
    }

    /// In `.paginated` mode, after a trackpad/scroll-wheel gesture ends,
    /// snaps the scroll position to the nearest page start so it lands on a
    /// "page" boundary. `.scrolling` mode is untouched (free continuous
    /// scroll).
    func handleScrollDidEndLiveScroll(_ notification: Notification) {
        guard settings.readerLayout == .paginated,
              let documentView = contentScrollView.documentView else { return }
        let clipView = contentScrollView.contentView
        let maxY = max(0, documentView.frame.height - clipView.bounds.height)
        guard let snappedY = Self.pageSnapOffset(
            for: clipView.bounds.origin.y, pageHeight: clipView.bounds.height, maximumOffset: maxY
        ) else { return }
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: snappedY))
        contentScrollView.reflectScrolledClipView(clipView)
        persistReadingProgress()
    }

    /// Page starts are multiples of the viewport height plus the final page,
    /// which starts at the maximum offset so a chapter tail shorter than a
    /// full page stays reachable. Returns the page start nearest to `offset`.
    static func pageSnapOffset(for offset: CGFloat, pageHeight: CGFloat, maximumOffset: CGFloat) -> CGFloat? {
        guard pageHeight > 0 else { return nil }
        let maximum = max(0, maximumOffset)
        let clamped = min(max(offset, 0), maximum)
        let lower = min((clamped / pageHeight).rounded(.down) * pageHeight, maximum)
        let upper = min(lower + pageHeight, maximum)
        return clamped - lower < upper - clamped ? lower : upper
    }

    func persistReadingProgress() {
        guard activeBookOpenJourneyID == nil || (activePreparedChapter != nil && hasRestoredInitialPosition),
              !isRestoringInitialPosition,
              let bookId = currentBookId, let documentView = contentScrollView.documentView else { return }
        let clipView = contentScrollView.contentView
        let scrollable = max(documentView.frame.height - clipView.bounds.height, 1)
        let fraction = clipView.bounds.origin.y / scrollable
        ReaderProgressStore.save(bookId: bookId, chapterIndex: selectedChapter, offsetFraction: fraction)
        if let chapter = chapter(at: selectedChapter) {
            var playbackFraction = clipView.bounds.origin.y / max(documentView.frame.height, 1)
            if let text = documentView as? NSTextView,
               text.string.utf16.count > 0 {
                if let visible = MacReaderTextLayout.characterRange(in: clipView.documentVisibleRect, of: text) {
                    playbackFraction = Double(visible.location)
                        / Double(text.string.utf16.count)
                }
            }
            ReaderPlaybackAnchor.publish(chapter: chapter, offsetFraction: playbackFraction, defaults: location.defaults)
        }
    }

    /// Called once, right after a fresh `loadCurrentBook()`, to jump back to
    /// the exact chapter + scroll fraction the user left off at. Runs on the
    /// next runloop tick so the scroll view has already been laid out.
    func restoreReadingProgressIfNeeded(bookId: String, completion: @escaping () -> Void) {
        let entry = hasRestoredInitialPosition ? nil : ReaderProgressStore.read(bookId: bookId)
        let generation = loadGeneration
        let presentation = presentationGeneration
        let chapterIndex = selectedChapter
        isRestoringInitialPosition = true
        initialPositionScheduler { [weak self] in
            guard let self, self.isActiveLoad(generation, bookID: bookId),
                  self.presentationGeneration == presentation else { return }
            if self.pendingAppearanceRefresh {
                self.pendingAppearanceRefresh = false
                self.applyCurrentReaderTheme()
                self.showChapter(self.selectedChapter)
            }
            self.view.layoutSubtreeIfNeeded()
            if self.contentScrollView.documentView === self.textView {
                MacReaderTextLayout.fit(self.textView, in: self.contentScrollView, columns: self.settings.readerColumns)
            }
            guard let documentView = self.contentScrollView.documentView else {
                self.isRestoringInitialPosition = false
                return
            }
            let clipView = self.contentScrollView.contentView
            let scrollable = max(documentView.frame.height - clipView.bounds.height, 0)
            // A navigation performed while layout was pending wins over
            // initial restoration; never move a newer chapter's viewport.
            if let entry, self.selectedChapter == chapterIndex {
                clipView.scroll(to: NSPoint(x: 0, y: entry.offsetFraction * scrollable))
                self.contentScrollView.reflectScrolledClipView(clipView)
                if let chapter = self.chapter(at: chapterIndex) {
                    ReaderPlaybackAnchor.publish(chapter: chapter, offsetFraction: entry.offsetFraction, defaults: self.location.defaults)
                }
            }
            self.isRestoringInitialPosition = false
            self.hasRestoredInitialPosition = true
            completion()
            if self.isActiveLoad(generation, bookID: bookId), self.selectedChapter != chapterIndex {
                self.persistReadingProgress()
            }
        }
    }

    func playFromVisiblePDFPosition(presentUnavailable: () -> Void) -> Bool {
        guard let pdf = contentScrollView.documentView as? MacReaderPDFView else { return false }
        if !pdf.playFromVisiblePosition() { presentUnavailable() }
        return true
    }

    func showPDF(_ url: URL) async -> Bool? {
        let generation = loadGeneration
        let bookID = currentBookId
        let view = MacReaderPDFView(frame: contentScrollView.contentView.bounds)
        // PDFKit owns page scrolling; its outer surface fills the reader viewport.
        view.autoresizingMask = [.width, .height]
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.onPlayFrom = { [weak self, weak view] anchor in
            guard let self, let view, self.contentScrollView.documentView === view,
                  self.loadGeneration == generation, self.currentBookId == bookID else { return }
            self.onPlayPDF?(anchor)
        }
        composition.setPageIndicatorShown(false)
        statusLabel.stringValue = L10n.string("reader.pdf")
        chapterTitleLabel.stringValue = ""
        contentScrollView.documentView = view
        let prepared = await Task.detached(priority: .userInitiated) { MacReaderPDFView.prepare(url) }.value
        guard contentScrollView.documentView === view, loadGeneration == generation,
              currentBookId == bookID, !Task.isCancelled else { return nil }
        view.audioMap = prepared.audioMap
        view.document = prepared.document
        composition.protectPDFOpeningPosition(view)
        return prepared.wasNormalized
    }
}
#endif
