import Combine
import Foundation

/// Connects a live playback request to local conversion selection without
/// starting another stream or persisting transport intent as download work.
@MainActor
final class PendingPlaybackNavigationBinding {
    private let bookID: String
    private let scheduler: LocalAudioConversionScheduler
    private var requestID: UUID?
    private var observation: AnyCancellable?

    init(
        player: AudioPlayer,
        bookID: String,
        scheduler: LocalAudioConversionScheduler? = nil
    ) {
        self.bookID = bookID
        self.scheduler = scheduler ?? .shared
        observation = player.$pendingNavigation.removeDuplicates().sink { [weak self] navigation in
            self?.update(navigation)
        }
    }

    func invalidate() {
        observation?.cancel()
        observation = nil
        clearRequest()
    }

    private func update(_ navigation: AudioPlayer.PendingNavigation?) {
        guard let navigation,
              EmbeddedConversionCoordinator.embeddedBookID(from: navigation.jobID) == bookID else {
            clearRequest()
            return
        }
        if requestID != navigation.requestID { clearRequest() }
        requestID = navigation.requestID
        scheduler.setPendingNavigation(bookID: bookID, requestID: navigation.requestID,
                                       chapterIndex: navigation.chapterIndex)
    }

    private func clearRequest() {
        guard let requestID else { return }
        scheduler.clearPendingNavigation(bookID: bookID, requestID: requestID)
        self.requestID = nil
    }
}
