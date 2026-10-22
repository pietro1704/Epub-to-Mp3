import Foundation

enum BookDetailConversionSnapshot {
    static func terminal(from snapshot: JobSnapshot, state: String, error: String) -> JobSnapshot {
        JobSnapshot(
            jobId: snapshot.jobId,
            state: state,
            bookTitle: snapshot.bookTitle,
            bookAuthor: snapshot.bookAuthor,
            coverUrl: snapshot.coverUrl,
            coverMimeType: snapshot.coverMimeType,
            engine: snapshot.engine,
            voice: snapshot.voice,
            language: snapshot.language,
            progressPercent: snapshot.progressPercent,
            chaptersTotal: snapshot.chaptersTotal,
            chaptersCompleted: snapshot.chaptersCompleted,
            chapterProgress: snapshot.chapterProgress,
            outputs: snapshot.outputs,
            logUrl: snapshot.logUrl,
            error: error,
            lastActivityAt: Date().timeIntervalSince1970
        )
    }

}
