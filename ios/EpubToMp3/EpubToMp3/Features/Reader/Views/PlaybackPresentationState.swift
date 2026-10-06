import Foundation

enum PlaybackPresentationState {
    static func chapterLabel(
        snapshot: JobSnapshot?,
        currentChapterIndex: Int
    ) -> String {
        if let snapshot,
           snapshot.playableChapters.indices.contains(currentChapterIndex) {
            return snapshot.playableChapters[currentChapterIndex].displayTitle
        }
        return L10n.string("player.chapter", max(0, currentChapterIndex) + 1)
    }

    static func progress(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration.isFinite, duration > 0, position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }
}