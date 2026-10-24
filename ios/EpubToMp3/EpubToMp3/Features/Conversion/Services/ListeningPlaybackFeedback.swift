import Foundation

// UI clock forwarding; Rust owns prefetch thresholds and generation identity.
extension ConverterPlaybackControl {
    @MainActor func trackPlayback(_ player: AudioPlayer) {
        enableListening()
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self, weak player] in
            guard let stream = player?.position else { return }
            for await position in stream {
                guard !Task.isCancelled, let self, let player else { return }
                guard player.durationSeconds.isFinite, player.durationSeconds > 0 else { continue }
                let chapter = player.activeStreamingChapterIndex ?? player.currentChapterIndex
                self.sendPlaybackFeedback(chapter: chapter, remaining: max(0, player.durationSeconds - position), rate: Double(player.rate.rawValue))
            }
        }
    }

}
