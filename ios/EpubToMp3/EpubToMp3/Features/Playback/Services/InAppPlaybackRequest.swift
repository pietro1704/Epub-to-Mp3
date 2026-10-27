import Foundation

enum InAppPlaybackRequest {
    struct State {
        var isPlaying = false
        var hasAudioQueue = false
        var isConverting = false
        var hasPlayableChapters = false
        var usesSpeechFallback = false
    }

    // A newly opened book has no producer yet. Request listening rather than
    // arming a resume intent that no conversion will ever consume.
    static func perform(
        state: State,
        controlPlayback: () -> Void,
        startListening: () -> Void
    ) {
        if state.isPlaying || state.hasAudioQueue || state.isConverting
            || state.hasPlayableChapters || state.usesSpeechFallback {
            controlPlayback()
        } else {
            startListening()
        }
    }
}
