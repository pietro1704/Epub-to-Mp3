import Foundation

/// Pure row model for the chapter list, shared by the UIKit list-config
/// collection view (`ChapterListCollectionView`) and unit tests. Kept
/// Foundation-only so it's testable off-device — mirrors
/// `LibraryGridLayoutMetrics`.
struct ChapterListRowModel: Identifiable, Equatable {
    let id: Int
    let title: String
    let charsText: String?
    let durationText: String?
    let isCompleted: Bool

    static func rows(from chapters: [JobSnapshot.Chapter]) -> [ChapterListRowModel] {
        chapters.map { chapter in
            ChapterListRowModel(
                id: chapter.index,
                title: chapter.displayTitle,
                charsText: chapter.chars.flatMap { $0 > 0 ? L10n.string("toc.charsCount", $0) : nil },
                durationText: chapter.durationSeconds.flatMap { $0 > 0 ? formatDuration($0) : nil },
                isCompleted: chapter.isCompleted
            )
        }
    }

    /// Combined accessibility label matching the SwiftUI row's
    /// `.accessibilityLabel` (title, completion state, duration).
    var accessibilityLabel: String {
        var parts = [title]
        if isCompleted { parts.append(L10n.string("chapterList.completed")) }
        if let durationText { parts.append(durationText) }
        return parts.joined(separator: ", ")
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
