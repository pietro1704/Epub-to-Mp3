#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import PDFKit
import Combine

/// Owns Mac chapter mounting and saved-position restoration after committed layout.
@MainActor
final class MacReaderTextPresentation {
    private let document: MacReaderDocument
    private let composition: MacReaderViewComposition
    private let settings: AppSettings
    private let preparedRenderer: PreparedChapterRenderer
    private let initialPositionScheduler: (@escaping @MainActor () -> Void) -> Void
    private let repaintSavedHighlights: (Int) -> Void
    private let prepareChapterProjection: (String, Int) -> Void
    private let selectCurrentTOCRow: () -> Void
    private let closeReader: () -> Void
    private let observeOpenStage: (String) -> Void
    private var settingsCancellables: Set<AnyCancellable> = []
    private var pdfView: PDFView?
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
    private var activeBookOpenJourneyID: UUID? {
        get { document.activeBookOpenJourneyID }
        set { document.activeBookOpenJourneyID = newValue }
    }
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

    init(document: MacReaderDocument, composition: MacReaderViewComposition, settings: AppSettings,
         renderer: PreparedChapterRenderer,
         initialPositionScheduler: @escaping (@escaping @MainActor () -> Void) -> Void,
         stageObserver: (@Sendable (String, UInt64) -> Void)?, repaintSavedHighlights: @escaping (Int) -> Void,
         prepareChapterProjection: @escaping (String, Int) -> Void, selectCurrentTOCRow: @escaping () -> Void,
         closeReader: @escaping () -> Void) {
        self.document = document
        self.composition = composition
        self.settings = settings
        preparedRenderer = renderer
        self.initialPositionScheduler = initialPositionScheduler
        self.repaintSavedHighlights = repaintSavedHighlights
        self.prepareChapterProjection = prepareChapterProjection
        self.selectCurrentTOCRow = selectCurrentTOCRow
        self.closeReader = closeReader
        observeOpenStage = { stageObserver?($0, DispatchTime.now().uptimeNanoseconds) }
    }

    private func isActiveLoad(_ id: UUID, bookID: String) -> Bool { document.isActiveLoad(id, bookID: bookID) }

    func observeAppearance() {
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
                self.contentScrollView.contentView.scroll(to: origin)
                self.contentScrollView.reflectScrolledClipView(self.contentScrollView.contentView)
                self.persistReadingProgress()
            }
            .store(in: &settingsCancellables)
    }

    func applyCurrentReaderTheme() {
        MacReaderTheme.apply(
            settings: settings,
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
                                           chapter: chapter, settings: settings, fontDirectoryURL: document.fontDirectoryURL)
        observeOpenStage("selected_chapter_restore_completed")
    }

    func showChapter(_ index: Int, scrollToEnd: Bool = false) {
        guard let chapter = chapter(at: index) else { return }
        presentationGeneration = UUID()
        chapterTitleLabel.stringValue = chapter.name ?? ""

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
                   settings: settings, fontDirectoryURL: document.fontDirectoryURL
               ) {
                textView.textStorage?.setAttributedString(NSAttributedString(attributedString: rendered))
            } else {
                textView.string = chapter.text
                textView.font = ReaderFontCatalog.font(for: settings.readerOverrideFontFamily ? settings.readerFontFamily : .original, size: settings.readerPointSize)
                textView.textColor = settings.readerColors.foreground
            }
            MacReaderTextLayout.fit(textView, in: contentScrollView)
            repaintSavedHighlights(index)
            // NSTextView's responder actions need not move this read-only
            // viewport. Commit its measured destination directly.
            let clipView = contentScrollView.contentView
            let end = max(0, textView.frame.height - clipView.bounds.height)
            clipView.scroll(to: NSPoint(x: 0, y: scrollToEnd ? end : 0))
            contentScrollView.reflectScrolledClipView(clipView)
        }
        ReaderPlaybackAnchor.publish(chapter: chapter, offsetFraction: 0)
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
        let page = max(1, visibleBounds.height * 0.9)
        let maximumY = max(0, documentView.frame.height - visibleBounds.height)
        let atStart = visibleBounds.origin.y <= 1
        let atEnd: Bool
        if let readerTextView = documentView as? NSTextView,
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

    /// In `.paginated` mode, after a trackpad/scroll-wheel gesture ends,
    /// rounds the scroll position to the nearest multiple of the viewport
    /// height so it lands on a "page" boundary. `.scrolling` mode is
    /// untouched (free continuous scroll).
    func handleScrollDidEndLiveScroll(_ notification: Notification) {
        guard settings.readerLayout == .paginated,
              let documentView = contentScrollView.documentView else { return }
        let clipView = contentScrollView.contentView
        let pageHeight = clipView.bounds.height
        guard pageHeight > 0 else { return }
        let page = (clipView.bounds.origin.y / pageHeight).rounded()
        let maxY = max(0, documentView.frame.height - pageHeight)
        let snappedY = min(max(page * pageHeight, 0), maxY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: snappedY))
        contentScrollView.reflectScrolledClipView(clipView)
        persistReadingProgress()
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
               let manager = text.layoutManager, let container = text.textContainer,
               text.string.utf16.count > 0 {
                var visible = clipView.documentVisibleRect
                visible.origin.y -= text.textContainerInset.height
                let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
                if glyphs.length > 0 {
                    playbackFraction = Double(manager.characterIndexForGlyph(at: glyphs.location))
                        / Double(text.string.utf16.count)
                }
            }
            ReaderPlaybackAnchor.publish(chapter: chapter, offsetFraction: playbackFraction)
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
                MacReaderTextLayout.fit(self.textView, in: self.contentScrollView)
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
                    ReaderPlaybackAnchor.publish(chapter: chapter, offsetFraction: entry.offsetFraction)
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

    func showPDF(_ url: URL) async -> Bool? {
        let generation = loadGeneration
        let bookID = currentBookId
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        pdfView = view
        statusLabel.stringValue = L10n.string("reader.pdf")
        chapterTitleLabel.stringValue = ""
        contentScrollView.documentView = view
        let normalized = await Task.detached(priority: .userInitiated) {
            PdfReadingPageNormalizer.normalizedDocument(from: url)
        }.value
        guard pdfView === view, loadGeneration == generation, currentBookId == bookID, !Task.isCancelled else { return nil }
        view.document = normalized ?? PDFDocument(url: url)
        return normalized != nil
    }
}
#endif
