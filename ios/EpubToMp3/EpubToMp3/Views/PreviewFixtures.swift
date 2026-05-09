import Foundation

/// Sample data used exclusively by `#Preview` blocks. Compiled in DEBUG
/// only so it never reaches a release binary. Mirrors realistic backend
/// payload shape for the iOS app, keeping the preview canvas usable
/// without a running server.
#if DEBUG
extension JobSnapshot {
    static let previewSample = JobSnapshot(
        jobId: "preview-job-id",
        state: "running",
        bookTitle: "Foundation",
        bookAuthor: "Isaac Asimov",
        coverUrl: nil,
        coverMimeType: nil,
        engine: "edge",
        voice: "en-US-JennyNeural",
        language: "en",
        progressPercent: 42.0,
        chaptersTotal: 5,
        chaptersCompleted: 2,
        chapterProgress: [
            .init(index: 0, name: "Prologue",
                  status: "completed",
                  downloadUrl: "/jobs/preview-job-id/chapter_001.mp3",
                  chars: 4321, charsProcessed: 4321,
                  progressRatio: 1.0,
                  durationSeconds: 180,
                  startedAt: nil, completedAt: nil),
            .init(index: 1, name: "Part I — The Psychohistorians",
                  status: "completed",
                  downloadUrl: "/jobs/preview-job-id/chapter_002.mp3",
                  chars: 9210, charsProcessed: 9210,
                  progressRatio: 1.0,
                  durationSeconds: 420,
                  startedAt: nil, completedAt: nil),
            .init(index: 2, name: "Part II — The Encyclopedists",
                  status: "running",
                  downloadUrl: nil,
                  chars: 7800, charsProcessed: 3120,
                  progressRatio: 0.4,
                  durationSeconds: nil,
                  startedAt: nil, completedAt: nil),
            .init(index: 3, name: "Part III — The Mayors",
                  status: "pending",
                  downloadUrl: nil,
                  chars: 8500, charsProcessed: 0,
                  progressRatio: 0.0,
                  durationSeconds: nil,
                  startedAt: nil, completedAt: nil),
            .init(index: 4, name: "Part IV — The Traders",
                  status: "pending",
                  downloadUrl: nil,
                  chars: 6700, charsProcessed: 0,
                  progressRatio: 0.0,
                  durationSeconds: nil,
                  startedAt: nil, completedAt: nil),
        ],
        outputs: nil,
        logUrl: nil,
        error: nil,
        lastActivityAt: nil
    )
}

extension EbookFulltext {
    static let previewSample = EbookFulltext(
        jobId: "preview-job-id",
        bookTitle: "Foundation",
        bookAuthor: "Isaac Asimov",
        chapters: [
            .init(index: 1,
                  name: "Prologue",
                  text: """
                  Hari Seldon stood at the edge of the empire and watched the stars.
                  He had spent forty years building psychohistory.
                  Now the equations were complete. The fall could be calculated.
                  Thirty thousand years of barbarism — or one thousand, if his plan held.
                  """,
                  html: nil, css: nil,
                  charCount: 240, segments: nil),
            .init(index: 2,
                  name: "Part I — The Psychohistorians",
                  text: """
                  The university domes glittered under twin moons.
                  Gaal Dornick walked the corridors with the wonder of a provincial.
                  He had studied Seldon's work since adolescence; meeting the man would
                  be the moment he had imagined a thousand times.
                  """,
                  html: nil, css: nil,
                  charCount: 260, segments: nil),
        ]
    )
}
#endif
