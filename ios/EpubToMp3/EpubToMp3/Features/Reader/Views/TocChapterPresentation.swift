#if os(iOS)
import Foundation

@MainActor
enum TocChapterPresentation {
    /// The active audio chapter is the listener's immediate context. When
    /// audio has not selected a chapter yet, preserve the reader's location.
    static func initialFocusChapterIndex(
        currentChapterIndex: Int,
        readingChapterIndex: Int?
    ) -> Int? {
        currentChapterIndex >= 0 ? currentChapterIndex : readingChapterIndex
    }

    /// A chapter-specific state always wins. A pending manifest entry has no
    /// active conversion of its own, so it may surface the book's FIFO or
    /// Wi-Fi wait state without falsely presenting every pending row as the
    /// chapter currently being generated.
    static func usesSchedulerStatus(
        artifactState: LocalAudioArtifactStore.ArtifactState?,
        schedulerState: LocalAudioConversionScheduler.WorkState?
    ) -> Bool {
        switch artifactState {
        case .none:
            return schedulerState != nil
        case .pending:
            return schedulerState == .queued || schedulerState == .waitingForWiFi || schedulerState == .waitingForResources
        case .generating, .waitingForWiFi, .available, .failed:
            return false
        }
    }

    static func artifactStatusText(for state: LocalAudioArtifactStore.ArtifactState?) -> String? {
        switch state {
        case .generating:
            return L10n.string("toc.audioPreparing")
        case .waitingForWiFi:
            return L10n.string("toc.waitingForWiFi")
        case .failed:
            return L10n.string("player.downloadFailed")
        case .pending, .available, .none:
            return nil
        }
    }

    static func schedulerStatusText(for state: LocalAudioConversionScheduler.WorkState?) -> String? {
        switch state {
        case .generating:
            return L10n.string("toc.audioPreparing")
        case .waitingForWiFi:
            return L10n.string("toc.waitingForWiFi")
        case .waitingForResources:
            return L10n.string("toc.audioPreparing")
        case .failed:
            return L10n.string("player.downloadFailed")
        case .queued:
            return L10n.string("toc.audioQueued")
        case .finished, .none:
            return nil
        }
    }

}
#endif
