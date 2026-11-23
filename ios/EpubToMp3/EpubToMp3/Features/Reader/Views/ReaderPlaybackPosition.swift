#if os(iOS)
import UIKit

/// Captures the position before dismissing the player or loading a reader.
@MainActor
struct ReaderPlaybackLocation {
    let chapterIndex: Int
    let seconds: TimeInterval
    let duration: TimeInterval
    let textOffset: Int
    let audio: PlaybackAudioOutput.Position?
    let spoken: SpeechFallbackPlayer.SpokenWord?

    init?(player: AudioPlayer) {
        let transport = player.captureTransportSample()
        let state = transport.content
        let audio = player.playbackClock.audioOutput.position
        let spoken = state.source == .speech ? player.speechOutput.spokenWord : nil
        let queueChapter = state.chapter
        let base = state.job?.chapterIndexBase == 1 ? 1 : 0
        let reportedIndex = state.streamingChapterIndex ?? audio?.chapterIndex
        // Segment playback reports a reader index; a whole-file queue reports a snapshot index.
        let reportedBase = state.usesSegmentQueue ? 0 : base
        guard let index = spoken?.chapterIndex ?? reportedIndex.map({ $0 - reportedBase })
                ?? queueChapter.map({ $0.index - base }),
              index >= 0 else { return nil }
        chapterIndex = index
        seconds = audio?.seconds ?? transport.clock.positionSeconds
        duration = audio?.duration ?? transport.clock.durationSeconds
        textOffset = state.usesSegmentQueue ? 0 : max(0, queueChapter?.textOffset ?? 0)
        self.audio = audio
        self.spoken = spoken
    }

    func characterOffset(chapterText: String, renderedText: String) -> Int {
        if let audio, let measured = audio.alignment?.spokenWord(at: audio.itemSeconds),
           let range = ReaderSpokenTextResolver.word(measured.word, passage: measured.passage,
                                                     chapterText: chapterText, renderedText: renderedText) {
            return range.location
        }
        let rendered = renderedText as NSString
        if let spoken, !spoken.text.isEmpty {
            let occurrence = rendered.range(of: spoken.text)
            if occurrence.location != NSNotFound, NSMaxRange(spoken.range) <= occurrence.length,
               rendered.range(of: spoken.text, range: NSRange(location: NSMaxRange(occurrence),
                length: rendered.length - NSMaxRange(occurrence))).location == NSNotFound {
                return occurrence.location + spoken.range.location
            }
        }
        return Self.estimatedOffset(seconds: seconds, duration: duration,
                                    textOffset: textOffset, sourceCount: chapterText.unicodeScalars.count,
                                    renderedCount: rendered.length)
    }

    static func estimatedOffset(seconds: Double, duration: Double, textOffset: Int,
                                sourceCount: Int, renderedCount: Int) -> Int {
        guard renderedCount > 0 else { return 0 }
        let start = Double(min(max(0, textOffset), max(1, sourceCount))) / Double(max(1, sourceCount))
        let progress = seconds.isFinite && duration.isFinite && duration > 0 ? min(1, max(0, seconds / duration)) : 0
        return min(renderedCount - 1, Int((start + (1 - start) * progress) * Double(renderedCount)))
    }
}

@MainActor
final class ReaderPlaybackPosition {
    let location: ReaderLocation
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private var lastPublishedReaderPageRatio: Double?

    init(document: ReaderBookDocument, composition: ReaderViewComposition, location: ReaderLocation) {
        self.location = location
        self.document = document
        self.composition = composition
    }

    func resetForChapter() { lastPublishedReaderPageRatio = 0 }

    func publish(_ anchor: ReaderReadingPosition.ReadingAnchor? = nil,
                 facts: ReaderReadingPosition.Facts, isViewportTransitioning: Bool) {
        guard composition.contentSurface.kind != .pdf else { return }
        let ratio: Double
        let textLength = composition.textView.attributedText.length
        var character = anchor?.characterOffset
        let canReadGlyphAnchor = document.hasRestoredInitialPosition && !facts.isLoading && !isViewportTransitioning
        if character == nil, canReadGlyphAnchor, facts.isPaginated,
           let fragment = facts.layoutResult?.protectedFragments.first(where: {
               $0.contentRect.minY >= composition.scrollView.contentOffset.y - 0.5
           }) {
            character = composition.textView.layoutManager.characterIndexForGlyph(at: fragment.glyphRange.location)
        }
        if character == nil, canReadGlyphAnchor, textLength > 0 {
            var visible = composition.textView.convert(composition.scrollView.bounds, from: composition.scrollView)
            visible.origin.y -= composition.textView.textContainerInset.top
            let glyphs = composition.textView.layoutManager.glyphRange(forBoundingRect: visible, in: composition.textView.textContainer)
            if glyphs.length > 0 { character = composition.textView.layoutManager.characterIndexForGlyph(at: glyphs.location) }
        }
        if let character, textLength > 0 {
            // Audio follows the first visible text, not the end of the scroll
            // range: the last page still starts before the chapter's last word.
            ratio = Double(min(max(character, 0), textLength)) / Double(textLength)
        } else if let anchor {
            ratio = Double(anchor.offsetFraction)
        } else {
            let scrollable = max(
                composition.scrollView.contentSize.height + composition.scrollView.contentInset.bottom - composition.scrollView.bounds.height,
                1
            )
            ratio = Double(min(max(composition.scrollView.contentOffset.y / scrollable, 0), 1))
        }
        guard ratio.isFinite else { return }
        if let previous = lastPublishedReaderPageRatio,
           abs(previous - ratio) < 0.001 {
            return
        }
        lastPublishedReaderPageRatio = ratio
        location.pageRatio = ratio
    }

}
#endif
