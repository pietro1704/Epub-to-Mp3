import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// Paint-only TextKit attributes preserve annotations, typography and the raw
/// reader offset. Clock samples may never navigate or repaginate the reader.
@MainActor
final class ReaderAudioHighlightPresentation {
    /// What one native reader shows and how it paints the narrated passage.
    struct Surface {
        let bookID: @MainActor () -> String?
        let chapter: @MainActor () -> EbookFulltext.Chapter?
        /// `nil` while no text surface is on screen.
        let renderedText: @MainActor () -> String?
        let paint: @MainActor (_ sentence: NSRange?, _ word: NSRange?) -> Void
    }

    private let player: AudioPlayer
    private let surface: Surface
    private var observation: AnyCancellable?
    private var speechObservation: AnyCancellable?
    private var transportObservation: AnyCancellable?
    private var settingsObservation: AnyCancellable?
    private var jumpObservation: AnyCancellable?
    /// The last narrated passage, shown again while paused to mark where narration resumes.
    private var held: (bookID: String, chapter: EbookFulltext.Chapter, text: String, sentence: NSRange?, word: NSRange?)?
    private var repaintTask: Task<Void, Never>?
    private var latestPosition: PlaybackAudioOutput.Position?
    private var observedAt: TimeInterval = 0
    private let settings: AppSettings
    private var trackingEnabled: Bool
    private let sync = SyncEngine()
    private var loadedChapter: EbookFulltext.Chapter?
    private var loadedDuration: TimeInterval = 0
    private var resolvedText: String?
    private var resolvedSentences: [String: NSRange] = [:]
    private var measuredPassage: SpeechAudioAlignment.Passage?
    private var measuredWordRanges: [Int: NSRange] = [:]

    init(player: AudioPlayer, settings: AppSettings, surface: Surface) {
        self.player = player
        self.settings = settings
        self.surface = surface
        self.trackingEnabled = settings.readerAudioTrackingEnabled
    }

    func observe() {
        settingsObservation = settings.$readerAudioTrackingEnabled.sink { [weak self] enabled in
            self?.trackingEnabled = enabled
            if !enabled { self?.held = nil }
            self?.refresh()
        }
        observation = player.playbackClock.audioOutput.$position.sink { [weak self] in self?.render($0) }
        speechObservation = player.speechOutput.$spokenWord.sink { [weak self] in self?.renderSpeech($0) }
        transportObservation = player.transportContentUpdates
            .sink { [weak self] _ in self?.refresh() }
        jumpObservation = player.narrationJumps.sink { [weak self] in
            self?.held = nil
            self?.clear()
        }
    }

    func refresh() {
        if player.isUsingSpeechFallback { renderSpeech(player.speechOutput.spokenWord) }
        else { render(player.playbackClock.audioOutput.position) }
    }

    func clear() {
        latestPosition = nil
        repaintTask?.cancel()
        repaintTask = nil
        paintPausedPassage()
    }

    /// Erases the paint, except for the passage where a paused narration will resume.
    private func paintPausedPassage() {
        if player.isSeeking { held = nil }
        guard let held, trackingEnabled, !player.isPlaying, player.isPlaybackForReaderBook(held.bookID),
              surface.bookID() == held.bookID, surface.chapter() == held.chapter,
              surface.renderedText() == held.text else {
            paint(sentence: nil, word: nil)
            return
        }
        paint(sentence: held.sentence, word: held.word)
    }

    private func narrate(sentence: NSRange?, word: NSRange?) {
        if sentence != nil || word != nil, let bookID = surface.bookID(), let chapter = surface.chapter(),
           let text = surface.renderedText() {
            held = (bookID, chapter, text, sentence, word)
        }
        paint(sentence: sentence, word: word)
    }

    func stop() {
        held = nil
        jumpObservation = nil
        observation = nil
        speechObservation = nil
        transportObservation = nil
        settingsObservation = nil
        clear()
    }

    private func render(_ position: PlaybackAudioOutput.Position?) {
        latestPosition = position
        observedAt = ProcessInfo.processInfo.systemUptime
        paintPosition(position)
        guard latestPosition != nil, repaintTask == nil else { return }
        repaintTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, let confirmed = self.latestPosition else { return }
                let age = ProcessInfo.processInfo.systemUptime - self.observedAt
                guard age < 0.8 else { self.clear(); return }
                self.paintPosition(Self.projected(confirmed, age: age, rate: Double(self.player.rate.rawValue)))
            }
        }
    }

    /// Repaint between confirmed audio samples without increasing the global
    /// player tick rate. Projection never survives missing/stale output.
    static func projected(_ position: PlaybackAudioOutput.Position, age: TimeInterval, rate: Double) -> PlaybackAudioOutput.Position {
        let advance = min(0.8, max(0, age)) * max(0, rate)
        func bounded(_ seconds: TimeInterval, duration: TimeInterval) -> TimeInterval {
            duration.isFinite && duration > 0 ? min(seconds + advance, max(0, duration - 0.001)) : seconds
        }
        return .init(chapterIndex: position.chapterIndex,
            seconds: bounded(position.seconds, duration: position.duration), duration: position.duration,
            sentenceID: position.sentenceID,
            itemSeconds: bounded(position.itemSeconds, duration: position.itemDuration), itemDuration: position.itemDuration,
            alignment: position.alignment)
    }

    private func paintPosition(_ position: PlaybackAudioOutput.Position?) {
        guard trackingEnabled, let position, player.isPlaying, !player.isSeeking,
              let bookID = surface.bookID(), player.isPlaybackForReaderBook(bookID),
              let renderedText = surface.renderedText(),
              let chapter = surface.chapter(),
              chapter.zeroBasedEpubIndex == position.chapterIndex else { clear(); return }
        if chapter != loadedChapter || position.duration != loadedDuration {
            sync.load(chapter: chapter, chapterDurationSeconds: position.duration)
            resolvedText = nil
            loadedChapter = chapter
            loadedDuration = position.duration
        }
        if resolvedText != renderedText {
            resolvedText = renderedText
            resolvedSentences = Self.sentenceRanges(spans: sync.spans, in: renderedText as NSString)
            measuredPassage = nil
            measuredWordRanges.removeAll()
        }
        if let measured = position.alignment?.spokenWord(at: position.itemSeconds) {
            if measuredPassage != measured.passage {
                measuredPassage = measured.passage
                measuredWordRanges = ReaderSpokenTextResolver.ranges(passage: measured.passage,
                    chapterText: chapter.text, renderedText: renderedText)
            }
            if let word = measuredWordRanges[measured.word.location] {
                let sentence = resolvedSentences.values.first { NSIntersectionRange($0, word).length > 0 }
                narrate(sentence: sentence, word: word)
                return
            }
        }
        let entry: SyncEngine.TimingEntry?
        if let id = position.sentenceID {
            entry = sync.timing.first { sync.readerSentenceID(forTimingID: $0.id) == sync.readerSentenceID(forTimingID: id) }
        } else {
            entry = sync.timing.first { position.seconds * 1000 >= Double($0.startMs) && position.seconds * 1000 < Double($0.endMs) }
        }
        guard let id = sync.readerSentenceID(forTimingID: entry?.id),
              let range = resolvedSentences[id] else { clear(); return }
        // Without measured alignment, a sentence estimate must never pretend
        // to identify the word currently audible. Old audio remains playable.
        narrate(sentence: range, word: nil)
    }

    static func sentenceRanges(spans: [SentenceSpan], in text: NSString) -> [String: NSRange] {
        var result: [String: NSRange] = [:]
        var cursor = 0
        for span in spans where !span.text.isEmpty {
            let range = text.range(of: span.text, range: NSRange(location: cursor, length: text.length - cursor))
            guard range.location != NSNotFound else { continue }
            result[span.id] = range
            cursor = NSMaxRange(range)
        }
        return result
    }

    private func renderSpeech(_ output: SpeechFallbackPlayer.SpokenWord?) {
        guard trackingEnabled, let output, player.isUsingSpeechFallback, player.isPlaying, !player.isSeeking,
              let bookID = surface.bookID(), player.isPlaybackForReaderBook(bookID),
              let renderedText = surface.renderedText(), let chapter = surface.chapter(),
              output.chapterIndex == chapter.zeroBasedEpubIndex else { clear(); return }
        let rendered = renderedText as NSString
        let base = rendered.range(of: output.text)
        guard base.location != NSNotFound, output.range.location >= 0,
              NSMaxRange(output.range) <= base.length else { clear(); return }
        // Reject ambiguous partial utterances rather than highlighting another
        // occurrence of the same paragraph in this chapter.
        let tail = NSRange(location: NSMaxRange(base), length: rendered.length - NSMaxRange(base))
        guard rendered.range(of: output.text, range: tail).location == NSNotFound else { clear(); return }
        let word = NSRange(location: base.location + output.range.location, length: output.range.length)
        let sentence = Self.sentenceRanges(spans: chapter.splitSentences(), in: rendered).values
            .first { NSIntersectionRange($0, word).length > 0 }
        narrate(sentence: sentence, word: sentence == nil ? nil : word)
    }

    private func paint(sentence: NSRange?, word: NSRange?) {
        surface.paint(sentence, word)
    }
}

#if os(iOS)
extension ReaderAudioHighlightPresentation {
    convenience init(document: ReaderBookDocument, player: AudioPlayer, textView: UITextView, settings: AppSettings) {
        self.init(player: player, settings: settings, surface: Surface(
            bookID: { document.book.id },
            chapter: {
                if let chapters = document.fulltext?.chapters, chapters.indices.contains(document.selectedChapter) {
                    return chapters[document.selectedChapter]
                }
                return document.activePreparedChapter?.chapter
            },
            renderedText: { [weak textView] in textView?.text },
            paint: { [weak textView] sentence, word in
                (textView?.layoutManager as? ReaderPlaybackLayoutManager)?.paint(sentence: sentence, word: word)
            }))
    }
}

/// UIKit has no temporary-attribute API. Paint backgrounds at its drawing seam,
/// retaining the underlying text storage and every glyph/layout calculation.
final class ReaderPlaybackLayoutManager: NSLayoutManager {
    private(set) var activeSentenceRange: NSRange?
    private(set) var activeWordRange: NSRange?

    func paint(sentence: NSRange?, word: NSRange?) {
        guard activeSentenceRange != sentence || activeWordRange != word else { return }
        let previous = [activeSentenceRange, activeWordRange]
        activeSentenceRange = sentence
        activeWordRange = word
        for range in (previous + [sentence, word]).compactMap({ $0 }) {
            guard let length = textStorage?.length, range.location < length else { continue }
            invalidateDisplay(forCharacterRange: NSRange(location: range.location,
                length: min(range.length, length - range.location)))
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        draw(activeSentenceRange, alpha: 0.20, visible: glyphsToShow, origin: origin)
        draw(activeWordRange, alpha: 0.65, visible: glyphsToShow, origin: origin)
    }

    /// The view that shows this layout. UIKit's TextKit 1 has no public way back from the layout manager to it.
    weak var hostTextView: UITextView?

    /// CONTRAST-AUDIT: the text under the highlight keeps WCAG AA in the reader's own theme colours.
    func contrastSafeAlpha(_ preferred: CGFloat, at location: Int) -> CGFloat {
        guard let textView = hostTextView else { return preferred }
        let traits = textView.traitCollection
        let text = (textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor)
            ?? textView.textColor ?? .label
        let background = textView.backgroundColor ?? .systemBackground
        func components(_ color: UIColor) -> WCAGContrast.RGB? { color.resolvedColor(with: traits).srgbComponents }
        guard let text = components(text), let background = components(background),
              let tint = components(.systemYellow) else { return preferred }
        return CGFloat(ReaderHighlightContrast.alpha(preferred: Double(preferred), tint: tint, text: text, background: background))
    }

    private func draw(_ characters: NSRange?, alpha: CGFloat, visible: NSRange, origin: CGPoint) {
        guard let characters, let length = textStorage?.length, NSMaxRange(characters) <= length else { return }
        let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: characters, actualCharacterRange: nil), visible)
        guard glyphs.length > 0, let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
        let alpha = contrastSafeAlpha(alpha, at: characters.location)
        UIColor.systemYellow.withAlphaComponent(alpha).setFill()
        enumerateEnclosingRects(forGlyphRange: glyphs,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
            UIBezierPath(rect: rect.offsetBy(dx: origin.x, dy: origin.y)).fill()
        }
    }
}
#endif
