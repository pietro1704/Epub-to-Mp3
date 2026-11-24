import Foundation

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
        let audio = player.playbackClock.audioOutput.position
        let spoken = player.isUsingSpeechFallback ? player.speechOutput.spokenWord : nil
        let queueChapter = player.currentPlaybackChapter
        let base = player.snapshot?.chapterIndexBase == 1 ? 1 : 0
        let reportedIndex = player.activeStreamingChapterIndex ?? audio?.chapterIndex
        // Segment playback reports a reader index; a whole-file queue reports a snapshot index.
        let reportedBase = player.usesSegmentQueue ? 0 : base
        guard let index = spoken?.chapterIndex ?? reportedIndex.map({ $0 - reportedBase })
                ?? queueChapter.map({ $0.index - base }),
              index >= 0 else { return nil }
        chapterIndex = index
        seconds = audio?.seconds ?? player.positionSeconds
        duration = audio?.duration ?? player.playbackClock.durationSeconds
        textOffset = player.usesSegmentQueue ? 0 : max(0, queueChapter?.textOffset ?? 0)
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
