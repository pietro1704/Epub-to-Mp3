import Foundation

/// STREAM-SEEK-PRIORITY (CONTEXT.md, "Streaming seek priority"): while streaming, wherever the listener navigates
/// (slider, next / previous chapter, +-N seconds, a chapter picked in the contents) becomes the top priority: the core
/// preempts the chapter in progress and synthesizes the destination next.
@MainActor
enum StreamingSeekPriority {
    /// Moves the playback window onto the destination chapter and asks the core to synthesize it first.
    @discardableResult
    static func apply(_ navigation: AudioPlayer.PendingNavigation, to control: ConverterPlaybackControl) -> Bool {
        control.updatePlaybackWindow(currentChapter: navigation.chapterIndex, chaptersAhead: 1)
        return control.prioritize(chapterIndex: navigation.chapterIndex)
    }
}
