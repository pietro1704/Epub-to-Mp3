#if os(iOS)
import UIKit

/// Owns chapter mounting and the final viewport's measured text facts. TextKit
/// boundaries and masks remain delegated to the one ReaderTextViewport.
@MainActor
final class ReaderTextPresentation {
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private let settings: AppSettings
    private let player: AudioPlayer
    private let preparedRenderer: PreparedChapterRenderer
    private let preparedPresentation: ReaderPreparedPresentation
    private let readingPosition: ReaderReadingPosition
    private let annotations: ReaderAnnotationsPresentation
    private let diagnostics: ReaderDiagnosticsPresentation
    private let applyColors: () -> Void
    private let showError: (String) -> Void
    private let completeLoading: () -> Void
    private let observeOpenStage: (String) -> Void
    var chromeHidden = false
    private var lastAppliedViewportConfiguration: ReaderViewportConfiguration?
    private var lastAppliedComicLayout: Bool?
    private(set) var paginatedPageOffsets: [CGFloat] = [0]
    private(set) var paginatedLayoutResult: ReaderPaginatedTextLayout.Result?
    var forcesScrollingForOversizedFragment = false
    private var lastPaginatedViewportSize: CGSize = .zero
    private var lastScrollingViewportSize: CGSize = .zero
    private(set) var lastRenderedTextSettings: ReaderTextSettings?
    var lastRenderedGeometry: (margin: Double, layout: ReaderLayout, showsNumbers: Bool)?
    var uiTestPageNumber: Int?
    private var needsTextLayoutRefresh = false
    private var lastInlineImageViewportWidth: CGFloat?

    var isPaginatedMode: Bool {
        settings.readerLayout == .paginated && !forcesScrollingForOversizedFragment
    }
    private var isUITestFixture: Bool { ProcessInfo.processInfo.arguments.contains("-uiTestFixture") }

    init(document: ReaderBookDocument, composition: ReaderViewComposition, settings: AppSettings,
         player: AudioPlayer, renderer: PreparedChapterRenderer, preparedPresentation: ReaderPreparedPresentation,
         readingPosition: ReaderReadingPosition, annotations: ReaderAnnotationsPresentation,
         diagnostics: ReaderDiagnosticsPresentation, stageObserver: (@Sendable (String, UInt64) -> Void)?,
         applyColors: @escaping () -> Void, showError: @escaping (String) -> Void,
         completeLoading: @escaping () -> Void) {
        self.document = document
        self.composition = composition
        self.settings = settings
        self.player = player
        preparedRenderer = renderer
        self.preparedPresentation = preparedPresentation
        self.readingPosition = readingPosition
        self.annotations = annotations
        self.diagnostics = diagnostics
        self.applyColors = applyColors
        self.showError = showError
        self.completeLoading = completeLoading
        observeOpenStage = { stageObserver?($0, DispatchTime.now().uptimeNanoseconds) }
    }

    private func publishTitles(_ payload: EbookFulltext) {
        for chapter in payload.chapters {
            player.updateReaderChapterTitle(chapter.displayTitle, for: chapter.zeroBasedEpubIndex)
        }
    }

    func applyReaderLayoutMode() {
        let configuration = ReaderViewportConfiguration.resolve(
            layout: settings.readerLayout,
            chromeHidden: chromeHidden,
            showsPageNumbers: settings.readerShowPageNumbers
        )
        let isDisplayingImageChapter = composition.contentSurface.isDisplayingComic
        let allowsTextScrolling = configuration.allowsVerticalScrolling && !isDisplayingImageChapter
        composition.scrollView.isScrollEnabled = allowsTextScrolling
        composition.scrollView.panGestureRecognizer.isEnabled = allowsTextScrolling
        composition.scrollView.alwaysBounceVertical = allowsTextScrolling
        composition.scrollView.alwaysBounceHorizontal = false
        composition.textView.isScrollEnabled = false
        composition.textView.panGestureRecognizer.isEnabled = false
        guard configuration != lastAppliedViewportConfiguration
                || isDisplayingImageChapter != lastAppliedComicLayout else { return }
        lastAppliedViewportConfiguration = configuration
        lastAppliedComicLayout = isDisplayingImageChapter
        composition.textView.textContainer.widthTracksTextView = !configuration.usesPaginatedTextHeight
        composition.textView.textContainer.heightTracksTextView = false
        composition.paginatedTextHeightConstraint.isActive = !isDisplayingImageChapter && configuration.usesPaginatedTextHeight
        composition.scrollingTextHeightConstraint.isActive = !isDisplayingImageChapter && !configuration.usesPaginatedTextHeight
        // Text container padding already provides the reading gutter. Keep
        // the scroll viewport on the safe-area edge in both chrome states so
        // the first line can never be clipped by an outer 8pt gap.
        composition.scrollTopToSafeArea.constant = 0
        composition.scrollBottomToPageIndicator.constant = -8
        composition.scrollBottomToSafeArea.constant = chromeHidden ? 0 : -8
        NSLayoutConstraint.deactivate([
            composition.scrollTopToSafeArea,
            composition.scrollTopToRoot,
            composition.scrollBottomToPageIndicator,
            composition.scrollBottomToSafeArea,
            composition.scrollBottomToRoot,
        ])
        if configuration.usesScreenEdges {
            NSLayoutConstraint.activate([composition.scrollTopToRoot, composition.scrollBottomToRoot])
        } else if configuration.showsPageIndicator {
            NSLayoutConstraint.activate([composition.scrollTopToSafeArea, composition.scrollBottomToPageIndicator])
        } else {
            NSLayoutConstraint.activate([composition.scrollTopToSafeArea, composition.scrollBottomToSafeArea])
        }
        composition.forwardChapterSwipe.isEnabled = configuration.allowsChapterSwipes
        composition.backwardChapterSwipe.isEnabled = configuration.allowsChapterSwipes
        composition.pageIndicator.isHidden = !configuration.showsPageIndicator
        composition.pageIndicator.alpha = configuration.showsPageIndicator ? 1 : 0
        lastPaginatedViewportSize = .zero
        lastScrollingViewportSize = .zero
    }

    func applyReaderMargins() {
        let margin = CGFloat(ReaderLayoutMetrics.clampedMargin(settings.readerMargin))
        composition.contentSurface.setTextMargins(margin)
    }

    func fitInlineImagesToTextViewport() {
        guard !composition.textView.isHidden, composition.textView.bounds.width > 0 else { return }
        let availableWidth = max(
            1,
            composition.textView.bounds.width - composition.textView.textContainerInset.left - composition.textView.textContainerInset.right
        )
        let displayScale = composition.view.window?.screen.scale ?? UIScreen.main.scale
        let viewportWidth = (availableWidth * displayScale).rounded() / displayScale
        guard lastInlineImageViewportWidth != viewportWidth else { return }
        lastInlineImageViewportWidth = viewportWidth
        guard let fitted = ReaderInlineImageLayout.fitting(
            composition.textView.attributedText,
            maximumWidth: viewportWidth
        ) else { return }
        composition.textView.attributedText = fitted
        requestTextLayoutRefresh()
    }

    func showUITestFixture() {
        let payload = EbookFulltext(
            jobId: "ui-test-job",
            bookTitle: document.book.resolvedTitle,
            bookAuthor: document.book.author,
            chapters: [
                .init(index: 1, name: "Chapter One", text: String(repeating: "Test reader content. ", count: 300), html: nil, css: nil, charCount: 6300, segments: nil),
                .init(index: 2, name: "Chapter Two", text: String(repeating: "Second chapter content. ", count: 300), html: nil, css: nil, charCount: 7200, segments: nil),
                .init(index: 3, name: "Chapter Three", text: String(repeating: "Third chapter content. ", count: 300), html: nil, css: nil, charCount: 6900, segments: nil),
                .init(index: 4, name: "Chapter Four", text: String(repeating: "Fourth chapter content. ", count: 300), html: nil, css: nil, charCount: 7200, segments: nil),
            ]
        )
        document.fulltext = payload
        publishTitles(payload)
        showChapter(0)
    }

    func showChapter(_ index: Int, preparedRendering: NSAttributedString? = nil) {
        guard let chapter = document.fulltext?.chapters[safe: index]
            ?? (document.activePreparedChapter?.chapterOrdinal == index ? document.activePreparedChapter?.chapter : nil) else { return }
        applyColors()
        readingPosition.forgetViewportOffsets()
        paginatedLayoutResult = nil
        composition.textViewport.resetForChapter()
        // The fallback belongs to a single measured chapter and viewport.
        // A new chapter must always be allowed to attempt canonical paging.
        forcesScrollingForOversizedFragment = false
        lastInlineImageViewportWidth = nil
        let epubIndex = ReaderPlaybackAnchor.epubIndex(
            forReaderPosition: index,
            in: document.fulltext?.chapters ?? []
        ) ?? chapter.zeroBasedEpubIndex
        UserDefaults.standard.set(epubIndex, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        UserDefaults.standard.set(0.0, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey)
        readingPosition.playback.resetForChapter()
        player.updateReaderChapterTitle(chapter.displayTitle, for: chapter.zeroBasedEpubIndex)
        synchronizeChromeVisibility()

        if chapter.isImageOnly {
            composition.contentSurface.mount(.comic)
            paginatedPageOffsets = [0]
            paginatedLayoutResult = nil
            applyReaderLayoutMode()
            if let base64 = chapter.resources?.first?.dataBase64,
               let data = Data(base64Encoded: base64),
               let image = UIImage(data: data) {
                composition.comicPageImageView.image = image
            } else {
                composition.comicPageImageView.image = nil
                showError(L10n.string("reader.noReadableContent"))
                return
            }
        } else {
            composition.contentSurface.mount(.text)
            applyReaderLayoutMode()
            let rendered: NSAttributedString?
            if let preparedRendering {
                observeOpenStage("prepared_render_reused")
                rendered = preparedRendering
            } else {
                observeOpenStage("prepared_render_generated")
                rendered = preparedRenderer.render(bookID: document.book.id, chapterIndex: index, chapter: chapter,
                    settings: settings, fontDirectoryURL: document.registeredFontURLs.first?.deletingLastPathComponent())
            }
            if let rendered, rendered.length > 0 {
                composition.textView.attributedText = rendered
            } else {
                let fallbackText = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? EpubHtmlRenderer.plainText(from: chapter.html ?? "")
                    : chapter.text
                composition.textView.text = fallbackText
                composition.textView.textColor = settings.readerColors.foreground
                let font = ReaderFontCatalog.font(for: settings.readerOverrideFontFamily ? settings.readerFontFamily : .original,
                    size: settings.readerPointSize)
                composition.textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
            }
            requestTextLayoutRefresh()
            annotations.repaintSavedHighlights(chapterIndex: index)
        }
        if isUITestFixture {
            uiTestPageNumber = 1
        } else {
            uiTestPageNumber = nil
        }
        lastRenderedTextSettings = ReaderTextSettings(settings: settings)
        lastRenderedGeometry = (settings.readerMargin, settings.readerLayout, settings.readerShowPageNumbers)
        updatePageIndicator()
        diagnostics.updateFlickerProbe()
    }

    /// Chapter rendering and page transitions can temporarily rebuild or
    /// snapshot the reader hierarchy. Re-apply the user's chrome preference
    /// so navigation never changes whether the controls are visible.
    func synchronizeChromeVisibility() {
        let configuration = ReaderViewportConfiguration.resolve(
            layout: settings.readerLayout,
            chromeHidden: chromeHidden,
            showsPageNumbers: settings.readerShowPageNumbers
        )
        composition.pageIndicator.isHidden = !configuration.showsPageIndicator
        composition.pageIndicator.alpha = configuration.showsPageIndicator ? 1 : 0
    }

    func updatePageIndicator() {
        guard composition.scrollView.bounds.height > 0 else {
            composition.pageIndicator.text = L10n.string("reader.pageOf", 1, 1)
            return
        }
        composition.textViewport.updateIndicator(testPage: isUITestFixture ? uiTestPageNumber : nil)
    }

    func updatePaginatedTextHeight() -> Bool {
        guard isPaginatedMode else { return false }
        guard let facts = composition.textViewport.presentPaginated(
            preservingRawOffset: readingPosition.isViewportTransitioning ? readingPosition.pendingViewportAnchor?.viewportOffset : nil
        ) else {
            return false
        }
        if facts.requiresScrollingFallback {
            forcesScrollingForOversizedFragment = true
            paginatedLayoutResult = nil
            return updateScrollingTextHeight()
        }
        forcesScrollingForOversizedFragment = false
        paginatedLayoutResult = facts.layoutResult
        paginatedPageOffsets = facts.canonicalPageOffsets
        diagnostics.updatePaginationProbe(layoutResult: paginatedLayoutResult, pageOffsets: paginatedPageOffsets, chromeHidden: chromeHidden)
        return true
    }


    /// TextKit can only start a page on a line boundary; a variable-height
    /// paragraph can still leave the next line crossing the physical bottom
    /// edge. Cover exactly that incomplete remainder, preserving every glyph
    /// on the next page instead of ever showing a chopped line.
    func updatePageOverflowGuard() {
        composition.textViewport.updateMasks(
            background: settings.readerColors.background,
            paginated: isPaginatedMode
        )
    }

    func updateScrollingTextHeight() -> Bool {
        let preservesOversizedFragmentFallback = forcesScrollingForOversizedFragment
        guard let facts = composition.textViewport.presentScrolling() else { return false }
        paginatedPageOffsets = [0]
        paginatedLayoutResult = nil
        forcesScrollingForOversizedFragment = preservesOversizedFragmentFallback || facts.requiresScrollingFallback
        return true
    }

    func updateTextHeightForCurrentLayout() {
        if isPaginatedMode {
            _ = updatePaginatedTextHeight()
        } else {
            _ = updateScrollingTextHeight()
        }
    }

    func requestTextLayoutRefresh() {
        needsTextLayoutRefresh = true
        composition.view.setNeedsLayout()
    }

    func layoutCommittedViewport() {
        applyReaderMargins()
        preparedPresentation.presentPreparedProjectionDuringCommittedLayoutIfReady()
        fitInlineImagesToTextViewport()
        if isPaginatedMode {
            let viewportSize = composition.scrollView.bounds.size
            if viewportSize.width > 0, viewportSize.height > 0,
               (needsTextLayoutRefresh || viewportSize != lastPaginatedViewportSize) {
                if updatePaginatedTextHeight() {
                    lastPaginatedViewportSize = viewportSize
                    needsTextLayoutRefresh = false
                    observeOpenStage("reader_viewport_text_layout_committed")
                }
            }
            updatePageIndicator()
            updatePageOverflowGuard()
            diagnostics.updatePaginationProbe(layoutResult: paginatedLayoutResult, pageOffsets: paginatedPageOffsets, chromeHidden: chromeHidden)
        } else {
            composition.pageOverflowGuard.isHidden = true
            composition.pageUnderflowGuard.isHidden = true
            let viewportSize = composition.scrollView.bounds.size
            if viewportSize.width > 0, viewportSize.height > 0,
               (needsTextLayoutRefresh || viewportSize != lastScrollingViewportSize) {
                if updateScrollingTextHeight() {
                    lastScrollingViewportSize = viewportSize
                    needsTextLayoutRefresh = false
                    observeOpenStage("reader_viewport_text_layout_committed")
                }
            }
        }
        if document.pendingProjectionAnchor != nil {
            composition.scrollView.layoutIfNeeded()
        }
        readingPosition.restorePendingViewportAnchorIfNeeded()
        preparedPresentation.finishPreparedProjectionLayoutIfNeeded()
        completeLoading()
        observeOpenStage("reader_view_did_layout_completed")
    }

}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
