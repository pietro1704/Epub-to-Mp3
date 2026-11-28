#if os(macOS)
import AppKit
import Combine
import PDFKit

/// Translates PDFKit's visible or clicked text to the Rust narration axis.
@MainActor
final class MacReaderPDFView: PDFView {
    var audioMap: PDFReadingAudioMap?
    var onPlayFrom: ((PDFReadingAudioMap.Anchor) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let click = NSClickGestureRecognizer(target: self, action: #selector(showPlaybackMenu(_:)))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated static func prepare(_ url: URL) -> (document: PDFDocument?, audioMap: PDFReadingAudioMap?, wasNormalized: Bool) {
        guard let document = PDFDocument(url: url) else { return (nil, nil, false) }
        let pageTexts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        if pageTexts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            // Rust supplies the same native text used for narration. The
            // scanned-spread path must not replace selectable source text.
            let metadata = try? ConverterFFIAdapter().openBook(at: url).metadataJSON
            let audioMap = metadata.flatMap {
                try? PDFReadingAudioMap(metadata: $0, pageTexts: PDFReadingAudioMap.pageTexts(of: document))
            }
            return (document, audioMap, false)
        }
        if let normalized = PdfReadingPageNormalizer.normalizedDocument(from: url) {
            return (normalized, nil, true)
        }
        return (document, nil, false)
    }

    private var positionObservers: Set<AnyCancellable> = []

    /// Reopens the saved position, then saves every later move. Call once, after the document is laid out:
    /// PDFKit's moves while opening must not replace the saved position.
    func keepPosition(bookID: String, defaults: UserDefaults) {
        positionObservers.removeAll()
        if let saved = ReaderProgressStore.savedPDFPosition(bookId: bookID, defaults: defaults),
           let page = document?.page(at: saved.page) {
            go(to: PDFDestination(page: page, at: CGPoint(x: saved.x, y: saved.y)))
        }
        var names = [Notification.Name.PDFViewPageChanged, .PDFViewVisiblePagesChanged]
            .map { NotificationCenter.default.publisher(for: $0, object: self) }
        // Scrolling within a page posts no PDFView notification.
        if let clip = documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            names.append(NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: clip))
        }
        Publishers.MergeMany(names).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition(bookID: bookID, defaults: defaults) }
        }.store(in: &positionObservers)
    }

    private func savePosition(bookID: String, defaults: UserDefaults) {
        guard window != nil, let document, let page = currentPage else { return }
        let index = document.index(for: page)
        // The reader chrome covers the top inset; a destination lands below it.
        var readable = bounds
        let covered = documentView?.enclosingScrollView?.contentInsets.top ?? 0
        readable.size.height = max(1, readable.height - covered)
        if isFlipped { readable.origin.y += covered }
        let visible = convert(readable, to: page)
        let box = page.bounds(for: displayBox)
        let x = min(max(visible.minX, box.minX), box.maxX)
        let y = min(max(visible.maxY, box.minY), box.maxY)
        guard index != NSNotFound, x.isFinite, y.isFinite else { return }
        ReaderProgressStore.savePDFPosition(.init(page: index, x: Double(x), y: Double(y)),
                                            bookId: bookID, defaults: defaults)
    }

    @discardableResult
    func playFromVisiblePosition() -> Bool {
        guard let document, let page = currentPage, let audioMap, let onPlayFrom else { return false }
        let viewport = convert(visibleRect, to: page).intersection(page.bounds(for: displayBox))
        guard !viewport.isEmpty else { return false }
        let character = firstCharacter(in: page.selection(for: viewport), on: page) ?? 0
        guard let anchor = audioMap.playbackAnchor(page: document.index(for: page), character: character) else { return false }
        play(from: anchor, using: onPlayFrom)
        return true
    }

    /// The narration chapter of the first text visible on the current page.
    var currentChapter: Int? {
        guard let document, let page = currentPage, let audioMap else { return nil }
        let viewport = convert(visibleRect, to: page).intersection(page.bounds(for: displayBox))
        let character = viewport.isEmpty ? 0 : firstCharacter(in: page.selection(for: viewport), on: page) ?? 0
        let index = document.index(for: page)
        // A page whose text does not match the narration still belongs to the last chapter begun by then.
        return audioMap.anchor(page: index, character: character)?.chapterIndex
            ?? audioMap.chapters.lastIndex { $0.startPage.map { $0 <= index } ?? false }
    }

    func goToChapter(_ chapter: Int) {
        guard let chapters = audioMap?.chapters, chapters.indices.contains(chapter),
              let index = chapters[chapter].startPage, let page = document?.page(at: index) else { return }
        go(to: page)
    }

    private func firstCharacter(in selection: PDFSelection?, on page: PDFPage) -> Int? {
        guard let selection,
              selection.numberOfTextRanges(on: page) > 0 else { return nil }
        let location = selection.range(at: 0, on: page).location
        return location == NSNotFound ? nil : location
    }

    func playbackMenu(at point: NSPoint) -> NSMenu? {
        guard let document, let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        if let annotation = page.annotation(at: pagePoint),
           annotation.action != nil || annotation.type == PDFAnnotationSubtype.link.rawValue { return nil }
        let character = page.characterIndex(at: pagePoint)
        guard character != NSNotFound, character >= 0 else { return nil }
        let wordStart = firstCharacter(in: page.selectionForWord(at: pagePoint), on: page) ?? character
        guard let anchor = audioMap?.anchor(page: document.index(for: page), character: wordStart) else { return nil }

        let play = NSMenuItem(title: L10n.string("reader.selection.playFromHere"),
                              action: #selector(playFromMenu(_:)), keyEquivalent: "")
        play.target = self
        play.representedObject = anchor
        let menu = NSMenu()
        menu.addItem(play)
        return menu
    }

    @objc private func showPlaybackMenu(_ click: NSClickGestureRecognizer) {
        let point = click.location(in: self)
        playbackMenu(at: point)?.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func playFromMenu(_ item: NSMenuItem) {
        guard let anchor = item.representedObject as? PDFReadingAudioMap.Anchor else { return }
        if let onPlayFrom { play(from: anchor, using: onPlayFrom) }
    }

    private var toldSkippedPages = false

    /// Starts playback, then says once per opened book what the narration leaves out.
    private func play(from anchor: PDFReadingAudioMap.Anchor, using start: (PDFReadingAudioMap.Anchor) -> Void) {
        start(anchor)
        guard !toldSkippedPages, let notice = audioMap?.skippedPagesNotice, let window else { return }
        toldSkippedPages = true
        let alert = NSAlert()
        alert.messageText = notice
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.beginSheetModal(for: window)
    }
}
#endif
