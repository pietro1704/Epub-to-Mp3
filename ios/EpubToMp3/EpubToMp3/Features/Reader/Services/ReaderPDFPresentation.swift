#if os(iOS)
import Combine
import PDFKit
import UIKit

@MainActor
final class ReaderPDFPresentation {
    let view: ReaderPDFView
    let bookID: String
    private let location: ReaderLocation
    private var defaults: UserDefaults { location.defaults }
    private weak var player: AudioPlayer?
    private var settings: AppSettings?
    private var observers: Set<AnyCancellable> = []
    private let sync = SyncEngine()
    private var timingIdentity: (chapter: Int, duration: Double)?
    private var sentenceRanges: [String: NSRange] = [:]
    private var latestAudio: PlaybackAudioOutput.Position?
    private var audioObservedAt: TimeInterval = 0
    private var searchSelection: PDFSelection?
    /// The last narrated passage, shown again while paused to mark where narration resumes.
    private var heldAudioSelection: PDFSelection?
    private var hasLoaded = false
    private var viewportPage: PDFPage?
    private var viewportOffset: CGPoint?
    private var viewportWidth: CGFloat = 0
    private var requestedLayout: ReaderLayout = .scrolling
    private var isViewportTransitioning = false
    private(set) var audioMap: PDFReadingAudioMap?
    var onToggleChrome: (() -> Void)?
    var onPlayFrom: ((PDFReadingAudioMap.Anchor) -> Void)?
    var onPositionChanged: ((PDFReadingAudioMap.Anchor?, Int, Int) -> Void)?

    init(view: ReaderPDFView, bookID: String, defaults: UserDefaults = .standard,
         settings: AppSettings? = nil, player: AudioPlayer? = nil) {
        self.view = view
        self.bookID = bookID
        self.location = ReaderLocation(defaults: defaults)
        self.settings = settings
        self.player = player
        view.autoScales = true
        view.onViewportResize = { [weak self] page in self?.configureDisplay(returningTo: page) }
        view.onReaderTap = { [weak self] point in self?.tap(at: point) }
        view.onReaderLongPress = { [weak self] point in self?.showActions(at: point) }
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewVisiblePagesChanged] {
            NotificationCenter.default.publisher(for: name, object: view).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.noteViewportMove()
                    self?.publishPosition()
                }
            }.store(in: &observers)
        }
        NotificationCenter.default.publisher(for: .PDFViewSelectionChanged, object: view).sink { [weak view] _ in
            MainActor.assumeIsolated { if view?.currentSelection != nil { view?.clearSelection() } }
        }.store(in: &observers)
        if let player {
            player.narrationJumps.sink { [weak self] in
                self?.heldAudioSelection = nil
                self?.latestAudio = nil
                self?.paintAudio()
            }.store(in: &observers)
            player.playbackClock.audioOutput.$position.sink { [weak self] position in
                self?.latestAudio = position
                self?.audioObservedAt = ProcessInfo.processInfo.systemUptime
                self?.paintAudio()
            }.store(in: &observers)
            player.transportContentUpdates.sink { [weak self] _ in self?.paintAudio() }.store(in: &observers)
            player.speechOutput.$spokenWord.sink { [weak self] _ in self?.paintAudio() }.store(in: &observers)
            Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.paintAudio() }.store(in: &observers)
            player.playbackClock.audioOutput.$position
                .throttle(for: .milliseconds(400), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] _ in self?.refreshPairing() }.store(in: &observers)
            player.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshPairing() }.store(in: &observers)
        }
        applyLayout(settings?.readerLayout ?? .scrolling)
        startFollowingNarration()
    }

    func load(document: PDFDocument?, metadata: Data?) {
        hasLoaded = false
        audioMap = nil
        heldAudioSelection = nil
        toldSkippedPages = false
        if let document, let metadata {
            audioMap = try? PDFReadingAudioMap(metadata: metadata,
                pageTexts: (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" })
        }
        view.document = document
        if let document, let saved = ReaderProgressStore.savedPDFPosition(bookId: bookID, defaults: defaults),
           let page = document.page(at: saved.page) {
            view.layoutIfNeeded()
            if view.isUsingPageViewController { view.go(to: page) }
            else { view.go(to: PDFDestination(page: page, at: CGPoint(x: saved.x, y: saved.y))) }
        }
        for (index, chapter) in (audioMap?.chapters ?? []).enumerated() {
            player?.updateReaderChapterTitle(chapter.name, for: index)
        }
        hasLoaded = true
        publishPosition()
    }

    private var documentScrollView: UIScrollView? {
        var ancestor = view.documentView?.superview
        while let candidate = ancestor {
            if let scroll = candidate as? UIScrollView { return scroll }
            ancestor = candidate.superview
        }
        return nil
    }

    var documentOffset: CGPoint? { documentScrollView?.contentOffset }

    func prepareForViewportTransition() {
        guard !isViewportTransitioning else { return }
        isViewportTransitioning = true
        viewportPage = view.currentPage
        viewportOffset = documentOffset
        viewportWidth = view.bounds.width
    }

    func completeViewportTransition() {
        guard isViewportTransitioning else { return }
        view.layoutIfNeeded()
        // A raw offset only survives a height change: another width rescales the pages.
        if !view.isUsingPageViewController, view.bounds.width == viewportWidth,
           let viewportOffset, let scroll = documentScrollView {
            // PDFDestination restoration can align the bottom of a page with
            // the new viewport and advance currentPage. A chrome resize owns
            // geometry only, so preserve the document scroll view's raw origin.
            scroll.setContentOffset(viewportOffset, animated: false)
        } else if let viewportPage {
            view.go(to: viewportPage)
        }
        viewportPage = nil
        viewportOffset = nil
        isViewportTransitioning = false
        publishPosition()
    }

    func applyLayout(_ mode: ReaderLayout) {
        requestedLayout = mode
        configureDisplay()
    }

    /// A page shown whole in a landscape viewport is unreadably small, so landscape
    /// always scrolls vertically at page width. Portrait restores the chosen layout.
    private func configureDisplay(returningTo resizedPage: PDFPage? = nil) {
        let isLandscape = view.bounds.width > view.bounds.height
        let mode: ReaderLayout = isLandscape ? .scrolling : requestedLayout
        let destination = resizedPage == nil ? view.currentDestination : nil
        let sourcePage = resizedPage ?? view.currentPage
        let targetMode: PDFDisplayMode = mode == .paginated ? .singlePage : .singlePageContinuous
        let direction: PDFDisplayDirection = mode == .paginated ? .horizontal : .vertical
        guard view.isUsingPageViewController != (mode == .paginated) || view.displayDirection != direction
            || (mode == .scrolling && view.displayMode != targetMode) else { return }
        let wasPaginated = view.isUsingPageViewController
        view.usePageViewController(false, withViewOptions: nil)
        view.displayMode = targetMode
        view.displayDirection = direction
        view.usePageViewController(mode == .paginated, withViewOptions: nil)
        view.autoScales = true
        view.layoutIfNeeded()
        // A paginated page is shown whole, and restoring its destination in the
        // continuous layout can land on the next page: return to the page itself.
        if mode == .paginated || wasPaginated || resizedPage != nil, let sourcePage { view.go(to: sourcePage) }
        else if let destination { view.go(to: destination) }
        publishPosition()
    }

    var currentPage: Int? {
        guard let document = view.document, let page = view.currentPage else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    var currentAnchor: PDFReadingAudioMap.Anchor? {
        guard let page = view.currentPage, let index = currentPage else { return nil }
        let visible = view.convert(view.bounds, to: page).intersection(page.bounds(for: view.displayBox))
        guard !visible.isEmpty, let audioMap else { return nil }
        var character = 0
        if let selection = page.selection(for: visible), selection.numberOfTextRanges(on: page) > 0 {
            let location = selection.range(at: 0, on: page).location
            if location != NSNotFound { character = location }
        }
        return audioMap.anchor(page: index, character: character)
    }

    func anchor(at point: CGPoint) -> PDFReadingAudioMap.Anchor? {
        guard let document = view.document, let page = view.page(for: point, nearest: false) else { return nil }
        let character = page.characterIndex(at: view.convert(point, to: page))
        guard character != NSNotFound, character >= 0 else { return nil }
        return audioMap?.anchor(page: document.index(for: page), character: character)
    }

    func persistPosition() {
        guard hasLoaded, !isViewportTransitioning, let sourcePage = view.currentPage,
              let document = view.document else { return }
        let page = document.index(for: sourcePage)
        let visible = view.convert(view.bounds, to: sourcePage)
        let bounds = sourcePage.bounds(for: view.displayBox)
        let x = min(max(visible.minX, bounds.minX), bounds.maxX)
        let y = min(max(visible.maxY, bounds.minY), bounds.maxY)
        guard page != NSNotFound, x.isFinite, y.isFinite else { return }
        // currentDestination can describe a neighboring page in continuous
        // mode. Persist the page reported to the reader and a point in it.
        ReaderProgressStore.savePDFPosition(.init(page: page, x: Double(x), y: Double(y)), bookId: bookID, defaults: defaults)
    }

    func refreshPosition() { publishPosition() }

    deinit {
        // The reader is going away: it no longer shows anything, so the player must offer "Go to reading".
        let pairing = player?.readerPairing
        let owner = ObjectIdentifier(self)
        Task { @MainActor in pairing?.release(owner: owner) }
    }

    /// Publishes whether a visible page holds the narrated character (see ReaderNarrationPairing) and, while the
    /// narration is playing and has left the visible pages, follows it (READER-FOLLOW-NARRATION).
    private func refreshPairing() {
        guard let player else { return }
        let paired = computePaired(player)
        player.readerPairing.publish(paired: paired, owner: ObjectIdentifier(self))
        follower?.evaluate(paired: paired)
    }

    /// Any page change that the reader did not make itself came from the user (page turn, scroll, contents).
    /// PDFKit may post a late notification for the reader's own move: landing on the narrated page is never a
    /// reason to stop following, so a paired page is ignored.
    private func noteViewportMove() {
        guard hasLoaded, !isViewportTransitioning, let player, !computePaired(player) else { return }
        follower?.userTurnedThePage()
    }

    private var follower: ReaderNarrationFollower?

    /// Starts following the narration of `bookID`; the reader owns the lifetime of the player subscription.
    private func startFollowingNarration() {
        guard follower == nil, let player else { return }
        let follower = ReaderNarrationFollower(player: player, bookID: bookID) { [weak self] location in
            guard self?.settings?.readerAutoScroll != false else { return }
            self?.revealPlaybackLocation(location)
        }
        follower.start { [weak self] in self?.refreshPairing() }
        self.follower = follower
    }

    private func computePaired(_ player: AudioPlayer) -> Bool {
        guard hasLoaded, player.isPlaybackForReaderBook(bookID), let map = audioMap, let document = view.document,
              let location = ReaderPlaybackLocation(player: player),
              map.chapters.indices.contains(location.chapterIndex) else { return false }
        let text = map.chapters[location.chapterIndex].text
        let offset = location.characterOffset(chapterText: text, renderedText: text)
        let spoken = map.displayLocation(chapter: location.chapterIndex, character: offset)?.page
        var visible = view.visiblePages.map { document.index(for: $0) }.filter { $0 != NSNotFound }
        if let current = currentPage { visible.append(current) }
        return ReaderNarrationPairing.isPaired(spokenPage: spoken, visiblePages: visible)
    }

    private func publishPosition() {
        guard hasLoaded, !isViewportTransitioning, let index = currentPage, let document = view.document else { return }
        refreshPairing()
        persistPosition()
        view.accessibilityValue = L10n.string("reader.pageOf", index + 1, document.pageCount)
        let anchor = currentAnchor
        if let anchor, location.readingBookID == bookID {
            location.readerChapter = anchor.chapterIndex
            location.pageRatio = anchor.ratio
        }
        onPositionChanged?(anchor, index + 1, document.pageCount)
    }

    func turnPage(forward: Bool) {
        if forward, view.canGoToNextPage { view.goToNextPage(nil) }
        else if !forward, view.canGoToPreviousPage { view.goToPreviousPage(nil) }
    }

    private func tap(at point: CGPoint) {
        if let page = view.page(for: point, nearest: false),
           let annotation = page.annotation(at: view.convert(point, to: page)),
           annotation.action != nil || annotation.type == PDFAnnotationSubtype.link.rawValue {
            return // Let PDFKit handle document links.
        }
        if let anchor = anchor(at: point) {
            presentPlaybackActions(at: point, anchor: anchor)
            return
        }
        switch ReaderTapAction.resolve(point: point, in: view.bounds, isPaginated: settings?.readerLayout == .paginated) {
        case .toggleChrome: onToggleChrome?()
        case .turnPage(let forward): turnPage(forward: forward)
        case .scrollScreen: break // PDF has no scrolling fallback; edge taps only exist in paginated mode
        case .none: break
        }
    }

    func playFromCurrentPosition() {
        // A textless current page has no anchor of its own; narration starts at the next page with text.
        guard let anchor = currentAnchor ?? currentPage.flatMap({ audioMap?.playbackAnchor(page: $0) }) else {
            showUnavailable(); return
        }
        play(from: anchor)
    }

    private var toldSkippedPages = false

    /// Starts playback, then says once per opened book what the narration leaves out.
    private func play(from anchor: PDFReadingAudioMap.Anchor) {
        onPlayFrom?(anchor)
        guard !toldSkippedPages, let notice = audioMap?.skippedPagesNotice,
              let controller = presenter(), controller.presentedViewController == nil else { return }
        toldSkippedPages = true
        let alert = UIAlertController(title: nil, message: notice, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
        controller.present(alert, animated: true)
    }

    private func showActions(at point: CGPoint) {
        presentPlaybackActions(at: point, anchor: anchor(at: point))
    }

    private func presentPlaybackActions(at point: CGPoint, anchor: PDFReadingAudioMap.Anchor?) {
        guard let controller = presenter(), controller.presentedViewController == nil else { return }
        let alert = UIAlertController(title: L10n.string("reader.selection.playFromHere"), message: nil, preferredStyle: .actionSheet)
        let play = UIAlertAction(title: L10n.string("reader.selection.playFromHere"), style: .default) { [weak self] _ in
            // The action sheet is still presented while its handler runs.
            if let anchor { DispatchQueue.main.async { self?.play(from: anchor) } }
        }
        play.isEnabled = anchor != nil
        alert.addAction(play)
        if anchor == nil { alert.message = L10n.string("reader.pdf.audioUnavailable") }
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        // Outside taps dismiss the action instead of reaching the PDF reader.
        alert.popoverPresentationController?.passthroughViews = []
        controller.present(alert, animated: true)
    }

    private func showUnavailable() {
        guard let controller = presenter(), controller.presentedViewController == nil else { return }
        let alert = UIAlertController(title: L10n.string("reader.selection.playFromHere"),
            message: L10n.string("reader.pdf.audioUnavailable"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
        controller.present(alert, animated: true)
    }

    func goToChapter(_ chapter: Int) {
        guard let map = audioMap, map.chapters.indices.contains(chapter),
              let index = map.chapters[chapter].startPage, let page = view.document?.page(at: index) else { return }
        view.go(to: page)
        publishPosition()
    }

    func revealPlaybackLocation(_ location: ReaderPlaybackLocation) {
        if follower?.isRevealing != true { follower?.userAskedToGoToReading() }
        let index = location.chapterIndex
        guard let map = audioMap, map.chapters.indices.contains(index) else { return }
        let text = map.chapters[index].text
        let offset = location.characterOffset(chapterText: text, renderedText: text)
        guard let match = map.displayLocation(chapter: index, character: offset),
              let page = view.document?.page(at: match.page) else {
            goToChapter(index)
            return
        }
        if !view.isUsingPageViewController,
           let text = page.string, match.character < text.utf16.count,
           let selection = page.selection(for: (text as NSString).rangeOfComposedCharacterSequence(at: match.character)) {
            let bounds = selection.bounds(for: page)
            view.go(to: PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY)))
        } else {
            view.go(to: page)
        }
        publishPosition()
    }

    func promptSearch() {
        guard let controller = presenter(), controller.presentedViewController == nil else { return }
        let alert = UIAlertController(title: L10n.string("reader.search.placeholder"), message: nil, preferredStyle: .alert)
        alert.addTextField()
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default) { [weak self, weak alert] _ in
            guard let self, let query = alert?.textFields?.first?.text, !query.isEmpty,
                  let result = view.document?.findString(query, withOptions: .caseInsensitive).first else { return }
            view.go(to: result)
            searchSelection = result
            heldAudioSelection = nil
            result.color = .systemYellow
            view.highlightedSelections = [result]
            publishPosition()
        })
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        controller.present(alert, animated: true)
    }

    private func presenter() -> UIViewController? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }

    private func paintAudio() {
        if player?.isSeeking == true || settings?.readerAudioTrackingEnabled != true { heldAudioSelection = nil }
        guard let player, player.isPlaying, !player.isSeeking, player.isPlaybackForReaderBook(bookID),
              settings?.readerAudioTrackingEnabled == true, let map = audioMap else {
            paintPausedPassage(); return
        }
        let chapterIndex: Int
        let range: NSRange?
        var measuredWord = false
        if player.isUsingSpeechFallback, let spoken = player.speechOutput.spokenWord,
           let index = spoken.chapterIndex, map.chapters.indices.contains(index) {
            chapterIndex = index
            measuredWord = true
            let text = map.chapters[index].text as NSString
            let occurrence = text.range(of: spoken.text)
            if occurrence.location != NSNotFound,
               text.range(of: spoken.text, range: NSRange(location: NSMaxRange(occurrence), length: text.length - NSMaxRange(occurrence))).location == NSNotFound,
               NSMaxRange(spoken.range) <= occurrence.length {
                range = NSRange(location: occurrence.location + spoken.range.location, length: spoken.range.length)
            } else { range = nil }
        } else if let latestAudio, map.chapters.indices.contains(latestAudio.chapterIndex),
                  ProcessInfo.processInfo.systemUptime - audioObservedAt < 0.8 {
            let position = ReaderAudioHighlightPresentation.projected(latestAudio,
                age: ProcessInfo.processInfo.systemUptime - audioObservedAt, rate: Double(player.rate.rawValue))
            chapterIndex = position.chapterIndex
            let text = map.chapters[chapterIndex].text
            if let measured = position.alignment?.spokenWord(at: position.itemSeconds),
               let word = ReaderSpokenTextResolver.word(measured.word, passage: measured.passage, chapterText: text,
                                                        renderedText: text),
               map.displayRange(chapter: chapterIndex, range: word) != nil {
                measuredWord = true
                range = word
            } else {
                // As in the EPUB reader, a word that cannot be located falls back to its sentence.
                range = approximateSentence(position, map: map)
            }
        } else { paintPausedPassage(); return }
        guard let range, let match = map.displayRange(chapter: chapterIndex, range: range),
              let page = view.document?.page(at: match.page), let selection = page.selection(for: match.range) else {
            paintPausedPassage(); return
        }
        selection.color = UIColor.systemYellow.withAlphaComponent(measuredWord ? 0.65 : 0.2)
        heldAudioSelection = selection
        view.highlightedSelections = [selection]
    }

    /// Erases the narration paint, except for the passage where a paused narration will resume.
    private func paintPausedPassage() {
        let paused = player.map { !$0.isPlaying && $0.isPlaybackForReaderBook(bookID) } ?? false
        view.highlightedSelections = ((paused ? heldAudioSelection : nil) ?? searchSelection).map { [$0] }
    }
    private func approximateSentence(_ position: PlaybackAudioOutput.Position, map: PDFReadingAudioMap) -> NSRange? {
        let index = position.chapterIndex
        if timingIdentity?.chapter != index || timingIdentity?.duration != position.duration {
            let source = map.chapters[index]
            let chapter = EbookFulltext.Chapter(index: index + 1, name: source.name, text: source.text,
                html: nil, css: nil, charCount: source.text.count, segments: nil)
            sync.load(chapter: chapter, chapterDurationSeconds: position.duration)
            sentenceRanges = ReaderAudioHighlightPresentation.sentenceRanges(spans: sync.spans, in: source.text as NSString)
            timingIdentity = (index, position.duration)
        }
        let entry = sync.timing.first {
            if let id = position.sentenceID { return sync.readerSentenceID(forTimingID: $0.id) == sync.readerSentenceID(forTimingID: id) }
            return position.seconds * 1000 >= Double($0.startMs) && position.seconds * 1000 < Double($0.endMs)
        }
        return sync.readerSentenceID(forTimingID: entry?.id).flatMap { sentenceRanges[$0] }
    }

}
#endif
