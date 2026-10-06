import Combine
import Foundation

/// Legacy no-op compatibility shell. Remote API playback owns conversion
/// scheduling; this type must not inspect embedded job identifiers.
@MainActor
final class PendingPlaybackNavigationBinding {
    private var observation: AnyCancellable?

    init(
        player: AudioPlayer,
        bookID: String,
        scheduler: LocalAudioConversionScheduler? = nil
    ) {
        _ = bookID
        _ = scheduler
        observation = player.$pendingNavigation.removeDuplicates().sink { [weak self] navigation in
            self?.update(navigation)
        }
    }

    func invalidate() {
        observation?.cancel()
        observation = nil
    }

    private func update(_ navigation: AudioPlayer.PendingNavigation?) {
        _ = navigation
    }
}
