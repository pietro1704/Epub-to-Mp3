import Foundation

/// Book-level conversion progress derived from every raw backend chapter.
/// This intentionally has no audio-position semantics: the current chapter's
/// seconds scrubber remains owned by `AudioPlayer`.
struct BookChapterProgress: Equatable {
    enum State: Equatable {
        case completed
        case running
        case queued
        case failed
    }

    struct Chapter: Identifiable, Equatable {
        let epubIndex: Int
        let title: String
        let state: State
        let ratio: Double
        let weight: Double
        let isPlayable: Bool
        let playableIndex: Int?

        var id: Int { epubIndex }
    }

    let chapters: [Chapter]
    let overallRatio: Double

    var totalWeight: Double { chapters.reduce(0) { $0 + $1.weight } }

    init(snapshot: JobSnapshot?) {
        let rawChapters = snapshot?.chapterProgress ?? []
        let playableIndices = rawChapters
            .filter { $0.downloadUrl?.isEmpty == false }
            .sorted { $0.index < $1.index }
            .enumerated()
            .reduce(into: [Int: Int]()) { result, item in
                result[item.element.index] = item.offset
            }

        chapters = rawChapters.sorted { $0.index < $1.index }.map { raw in
            let ratio = Self.ratio(for: raw)
            let playable = raw.downloadUrl?.isEmpty == false
            return Chapter(
                epubIndex: raw.index,
                title: raw.displayTitle,
                state: Self.state(for: raw, ratio: ratio),
                ratio: ratio,
                weight: Double(max(raw.chars ?? 0, 1)),
                isPlayable: playable,
                playableIndex: playableIndices[raw.index]
            )
        }

        let totalWeight = chapters.reduce(0) { $0 + $1.weight }
        overallRatio = totalWeight > 0
            ? chapters.reduce(0) { $0 + $1.ratio * $1.weight } / totalWeight
            : 0
    }

    func playableIndex(forEPUBIndex index: Int) -> Int? {
        chapters.first(where: { $0.epubIndex == index })?.playableIndex
    }

    func epubIndex(forPlayableIndex index: Int) -> Int? {
        chapters.first(where: { $0.playableIndex == index })?.epubIndex
    }

    private static func ratio(for chapter: JobSnapshot.Chapter) -> Double {
        let rawRatio: Double
        if let progressRatio = chapter.progressRatio {
            rawRatio = progressRatio
        } else if let chars = chapter.chars, chars > 0, let processed = chapter.charsProcessed {
            rawRatio = Double(processed) / Double(chars)
        } else {
            rawRatio = 0
        }
        return min(1, max(0, rawRatio.isFinite ? rawRatio : 0))
    }

    private static func state(for chapter: JobSnapshot.Chapter, ratio: Double) -> State {
        switch chapter.status?.lowercased() {
        case "completed", "done", "finished": return .completed
        case "running", "processing", "converting", "in_progress": return .running
        case "failed", "error": return .failed
        case "queued", "pending", "waiting": return .queued
        default: return ratio >= 1 ? .completed : .queued
        }
    }
}
