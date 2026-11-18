import Foundation

/// Composes only snapshots whose caller has resolved the book's current job.
/// Legacy snapshots with an undeclared index axis remain separate until their
/// chapter mapping is proven by the migration coordinator.
enum LocalAudioPlaybackRestoration {
    static func snapshot(
        bookID: String, conversionJobID: String?,
        retained: JobSnapshot?, converted: JobSnapshot?
    ) -> JobSnapshot? {
        let retained = retained.flatMap { candidate -> JobSnapshot? in
            guard candidate.jobId == "embedded-\(bookID)", candidate.chapterIndexBase == 0,
                  validIndices(candidate) else { return nil }
            return candidate
        }
        let converted = converted.flatMap { candidate -> JobSnapshot? in
            guard let conversionJobID, candidate.jobId == conversionJobID else { return nil }
            return candidate
        }
        guard let converted else { return retained }
        guard let retained, converted.chapterIndexBase == 0, validIndices(converted) else {
            return converted
        }
        // The current job owns conflicting chapters and their timing/offset
        // metadata. Retained audio fills gaps; it never masks a newer job.
        var chapters = converted.playableChapters
        let currentIndices = Set(chapters.map(\.index))
        chapters += retained.playableChapters.filter { chapter in
            !currentIndices.contains(chapter.index)
                && converted.sourceChaptersTotal.map { chapter.index < $0 } != false
        }
        chapters.sort { $0.index < $1.index }
        let total = converted.sourceChaptersTotal
        let completedIndices = Set(chapters.filter { $0.isCompleted && ($0.textOffset ?? 0) == 0 }.map(\.index))
        return JobSnapshot(
            jobId: converted.jobId, state: converted.state,
            bookTitle: converted.bookTitle, bookAuthor: converted.bookAuthor,
            coverUrl: converted.coverUrl, coverMimeType: converted.coverMimeType,
            engine: converted.engine, voice: converted.voice, language: converted.language,
            progressPercent: converted.progressPercent,
            chaptersTotal: max(converted.chaptersTotal ?? 0, chapters.count),
            chaptersCompleted: completedIndices.count, chapterProgress: chapters,
            outputs: converted.outputs, logUrl: converted.logUrl, error: converted.error,
            lastActivityAt: max(converted.lastActivityAt ?? 0, retained.lastActivityAt ?? 0),
            chapterIndexBase: 0, sourceChaptersTotal: total)
    }

    private static func validIndices(_ snapshot: JobSnapshot) -> Bool {
        let chapters = snapshot.chapterProgress ?? []
        return !chapters.isEmpty && chapters.allSatisfy { $0.index >= 0 }
            && Set(chapters.map(\.index)).count == chapters.count
    }
}
