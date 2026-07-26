import Foundation

/// Playback-facing state for one chapter row in a conversion list.
///
/// The backend chapter index is sparse when non-playable chapters are present,
/// so the audio queue index must be derived from the snapshot rather than from
/// the row's position in the source array.
struct ChapterListRowState: Equatable {
    let isPlayable: Bool
    let playableIndex: Int?
    let isCurrent: Bool

    static func resolve(
        chapter: JobSnapshot.Chapter,
        snapshot: JobSnapshot,
        currentPlayableIndex: Int?
    ) -> ChapterListRowState {
        let playableChapters = (snapshot.chapterProgress ?? [])
            .filter { $0.downloadUrl?.isEmpty == false }
            .sorted { $0.index < $1.index }
        let playableIndex = playableChapters.firstIndex { $0.index == chapter.index }
        return ChapterListRowState(
            isPlayable: playableIndex != nil,
            playableIndex: playableIndex,
            isCurrent: playableIndex != nil && playableIndex == currentPlayableIndex
        )
    }
}
