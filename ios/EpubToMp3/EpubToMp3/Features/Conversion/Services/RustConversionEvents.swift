import Foundation

extension RustConversionCoordinator {
    struct ConversionProgressEvent: Decodable, Sendable {
        let jobId: String
        let state: String
        let chapterIndex: Int?
        let chaptersTotal: Int
        let chaptersCompleted: Int
        let percent: Double
        let engine: String?
        var modelId: String? = nil
        var voice: String? = nil
        var fallbackUsed: Bool? = nil
        let message: String

        func updating(_ snapshot: JobSnapshot) -> JobSnapshot {
            guard jobId == snapshot.jobId else { return snapshot }
            let resolvedEngine = engine ?? snapshot.engine
            // A provider change without voice metadata must not retain the old provider's voice.
            let resolvedVoice = modelId ?? voice ?? (resolvedEngine == snapshot.engine ? snapshot.voice : nil)
            return JobSnapshot(
                jobId: snapshot.jobId,
                state: "running",
                bookTitle: snapshot.bookTitle,
                bookAuthor: snapshot.bookAuthor,
                coverUrl: snapshot.coverUrl,
                coverMimeType: snapshot.coverMimeType,
                engine: resolvedEngine,
                voice: resolvedVoice,
                language: snapshot.language,
                progressPercent: percent,
                chaptersTotal: chaptersTotal,
                chaptersCompleted: chaptersCompleted,
                chapterProgress: snapshot.chapterProgress,
                outputs: snapshot.outputs,
                logUrl: snapshot.logUrl,
                error: nil,
                lastActivityAt: Date().timeIntervalSince1970,
                chapterIndexBase: snapshot.chapterIndexBase
            )
        }
    }

    struct ChapterCompletionEvent: Decodable, Sendable {
        let jobId: String
        let bookTitle: String
        let bookAuthor: String
        let chapterIndex: Int
        let chaptersTotal: Int
        let chaptersCompleted: Int
        let chapterTitle: String
        let filename: String
        let audioPath: URL
        let textChars: Int
        var engine: String? = nil
        var modelId: String? = nil
        var voice: String? = nil

        var progressPercent: Double {
            Double(chaptersCompleted) / Double(max(chaptersTotal, 1)) * 100
        }

        var playableChapter: JobSnapshot.Chapter {
            JobSnapshot.Chapter(
                index: chapterIndex,
                name: chapterTitle,
                status: "completed",
                downloadUrl: audioPath.path,
                chars: textChars,
                charsProcessed: textChars,
                progressRatio: 1,
                durationSeconds: nil,
                startedAt: nil,
                completedAt: nil
            )
        }

        func snapshot(chapters: [JobSnapshot.Chapter], preserving current: JobSnapshot? = nil) -> JobSnapshot {
            if let current, current.jobId != jobId { return current }
            let resolvedEngine = engine ?? current?.engine
            let resolvedVoice = modelId ?? voice ?? (resolvedEngine == current?.engine ? current?.voice : nil)
            return JobSnapshot(
                jobId: jobId,
                state: "running",
                bookTitle: bookTitle,
                bookAuthor: bookAuthor,
                coverUrl: current?.coverUrl,
                coverMimeType: current?.coverMimeType,
                // Chapter events add artifacts without replacing resolved provider metadata.
                engine: resolvedEngine,
                voice: resolvedVoice,
                language: current?.language,
                progressPercent: progressPercent,
                chaptersTotal: chaptersTotal,
                chaptersCompleted: chaptersCompleted,
                chapterProgress: chapters,
                outputs: current?.outputs,
                logUrl: current?.logUrl,
                error: nil,
                lastActivityAt: Date().timeIntervalSince1970,
                chapterIndexBase: 0
            )
        }
    }

}

extension RustConversionCoordinator.ChapterCompletionEvent {
    private enum CodingKeys: String, CodingKey {
        case jobId, bookTitle, bookAuthor, chapterIndex, chaptersTotal, chaptersCompleted
        case chapterTitle, filename, audioPath, textChars, engine, modelId, voice
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try values.decode(String.self, forKey: .jobId)
        bookTitle = try values.decode(String.self, forKey: .bookTitle)
        bookAuthor = try values.decode(String.self, forKey: .bookAuthor)
        chapterIndex = try values.decode(Int.self, forKey: .chapterIndex)
        chaptersTotal = try values.decode(Int.self, forKey: .chaptersTotal)
        chaptersCompleted = try values.decode(Int.self, forKey: .chaptersCompleted)
        chapterTitle = try values.decode(String.self, forKey: .chapterTitle)
        filename = try values.decode(String.self, forKey: .filename)
        textChars = try values.decode(Int.self, forKey: .textChars)
        engine = try values.decodeIfPresent(String.self, forKey: .engine)
        modelId = try values.decodeIfPresent(String.self, forKey: .modelId)
        voice = try values.decodeIfPresent(String.self, forKey: .voice)
        let path = try values.decode(String.self, forKey: .audioPath)
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw DecodingError.dataCorruptedError(forKey: .audioPath, in: values,
                                                  debugDescription: "Chapter audio requires an absolute local file path.")
        }
        // Rust serializes a filesystem path, not a URI. Preserve literal #, ? and %.
        audioPath = URL(fileURLWithPath: path)
    }
}
