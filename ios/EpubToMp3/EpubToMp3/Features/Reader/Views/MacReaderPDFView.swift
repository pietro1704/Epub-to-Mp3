#if os(macOS)
import AppKit
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
            let audioMap = metadata.flatMap { try? PDFReadingAudioMap(metadata: $0, pageTexts: pageTexts) }
            return (document, audioMap, false)
        }
        if let normalized = PdfReadingPageNormalizer.normalizedDocument(from: url) {
            return (normalized, nil, true)
        }
        return (document, nil, false)
    }

    @discardableResult
    func playFromVisiblePosition() -> Bool {
        guard let document, let page = currentPage, let audioMap, let onPlayFrom else { return false }
        let viewport = convert(visibleRect, to: page).intersection(page.bounds(for: displayBox))
        guard !viewport.isEmpty else { return false }
        let character = firstCharacter(in: page.selection(for: viewport), on: page) ?? 0
        guard let anchor = audioMap.playbackAnchor(page: document.index(for: page), character: character) else { return false }
        onPlayFrom(anchor)
        return true
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
        onPlayFrom?(anchor)
    }
}
#endif
