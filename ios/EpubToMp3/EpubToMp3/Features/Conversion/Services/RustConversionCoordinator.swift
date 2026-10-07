import Foundation

private let rustConversionQueue = DispatchQueue(label: "com.pietrocode.epubtomp3.rust-conversion", qos: .userInitiated)

private struct RustConversionInvocation: @unchecked Sendable {
    let adapter: ConverterFFIAdapter
}

/// Local conversion entry point shared by the Apple clients.
///
/// This type deliberately has no transport or backend dependency. The Rust
/// FFI owns EPUB parsing, model selection, conversion, and artifact creation.
final class RustConversionCoordinator {
    struct ConversionProgressEvent: Decodable, Sendable {
        let jobId: String
        let state: String
        let chapterIndex: Int?
        let chaptersTotal: Int
        let chaptersCompleted: Int
        let percent: Double
        let engine: String?
        let message: String

        func updating(_ snapshot: JobSnapshot) -> JobSnapshot {
            JobSnapshot(
                jobId: snapshot.jobId,
                state: "running",
                bookTitle: snapshot.bookTitle,
                bookAuthor: snapshot.bookAuthor,
                coverUrl: snapshot.coverUrl,
                coverMimeType: snapshot.coverMimeType,
                engine: engine ?? snapshot.engine,
                voice: snapshot.voice,
                language: snapshot.language,
                progressPercent: percent,
                chaptersTotal: chaptersTotal,
                chaptersCompleted: chaptersCompleted,
                chapterProgress: snapshot.chapterProgress,
                outputs: snapshot.outputs,
                logUrl: snapshot.logUrl,
                error: nil,
                lastActivityAt: Date().timeIntervalSince1970
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

        func snapshot(chapters: [JobSnapshot.Chapter]) -> JobSnapshot {
            JobSnapshot(
                jobId: jobId,
                state: "running",
                bookTitle: bookTitle,
                bookAuthor: bookAuthor,
                coverUrl: nil,
                coverMimeType: nil,
                engine: "edge",
                voice: nil,
                language: nil,
                progressPercent: progressPercent,
                chaptersTotal: chaptersTotal,
                chaptersCompleted: chaptersCompleted,
                chapterProgress: chapters,
                outputs: nil,
                logUrl: nil,
                error: nil,
                lastActivityAt: Date().timeIntervalSince1970
            )
        }
    }

    struct Result: Sendable {
        let jobID: String
        let manifestJSON: Data
        let outputDirectory: URL

        func snapshot() throws -> JobSnapshot {
            let envelope = try JSONDecoder().decode(Envelope.self, from: manifestJSON)
            guard envelope.manifest.jobId == jobID else {
                throw EmbeddedConverterError.conversionFailed(
                    "Rust returned job ID \(envelope.manifest.jobId) for request \(jobID)."
                )
            }
            let chapters = envelope.manifest.chapters.enumerated().map { offset, chapter in
                JobSnapshot.Chapter(
                    index: chapter.sourceIndex ?? offset,
                    name: chapter.title,
                    status: "completed",
                    downloadUrl: outputDirectory.appendingPathComponent(chapter.filename).path,
                    chars: chapter.textChars,
                    charsProcessed: chapter.textChars,
                    progressRatio: 1,
                    durationSeconds: nil,
                    startedAt: nil,
                    completedAt: nil
                )
            }
            return JobSnapshot(
                jobId: envelope.manifest.jobId,
                state: "finished",
                bookTitle: envelope.manifest.title,
                bookAuthor: envelope.manifest.author,
                coverUrl: envelope.manifest.cover.map { outputDirectory.appendingPathComponent($0).path },
                coverMimeType: nil,
                engine: nil,
                voice: nil,
                language: nil,
                progressPercent: 100,
                chaptersTotal: chapters.count,
                chaptersCompleted: chapters.count,
                chapterProgress: chapters,
                outputs: nil,
                logUrl: nil,
                error: nil,
                lastActivityAt: Date().timeIntervalSince1970
            )
        }
    }

    private struct Envelope: Decodable {
        let manifest: Manifest
    }
    private struct Manifest: Decodable {
        let jobId: String
        let title: String
        let author: String
        let chapters: [Chapter]
        let cover: String?
    }
    private struct Chapter: Decodable {
        let title: String?
        let filename: String
        let textChars: Int
        let sourceIndex: Int?
    }

    private let adapter: ConverterFFIAdapter
    private let fileManager: FileManager

    init(
        adapter: ConverterFFIAdapter = ConverterFFIAdapter(),
        fileManager: FileManager = .default
    ) {
        self.adapter = adapter
        self.fileManager = fileManager
    }

    func convert(
        bookURL: URL,
        jobID: String = UUID().uuidString,
        chapterStart: Int32 = -1,
        chapterEnd: Int32 = -1,
        onProgress: (@MainActor @Sendable (ConversionProgressEvent) -> Void)? = nil,
        onChapterCompleted: (@MainActor @Sendable (ChapterCompletionEvent) -> Void)? = nil
    ) async throws -> Result {
        let requestedChapterPositions = requestedChapterRange(
            chapterStart: chapterStart,
            chapterEnd: chapterEnd
        )
        if let requestedChapterPositions {
            try validateChapterSelection(
                in: bookURL,
                requestedPositions: requestedChapterPositions
            )
        }
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let outputDirectory = root
            .appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("RustConversions", isDirectory: true)
            .appendingPathComponent(jobID, isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let logURL = outputDirectory.appendingPathComponent("conversion.log")
        try? appendLogLine("[Rust] conversion started: \(bookURL.lastPathComponent)", to: logURL)

        do {
            let manifest = try await withCheckedThrowingContinuation { continuation in
                let invocation = RustConversionInvocation(adapter: self.adapter)
                rustConversionQueue.async {
                    do {
                        let data = try invocation.adapter.convertBook(
                    at: bookURL,
                    outputDirectory: outputDirectory,
                    jobID: jobID,
                    chapterStart: chapterStart,
                    chapterEnd: chapterEnd,
                    onProgress: { data in
                        guard let onProgress,
                              let event = try? JSONDecoder().decode(ConversionProgressEvent.self, from: data) else {
                            return
                        }
                        Task { @MainActor in onProgress(event) }
                    },
                    onChapterCompleted: { data in
                        guard let onChapterCompleted,
                              let event = try? JSONDecoder().decode(ChapterCompletionEvent.self, from: data) else {
                            return
                        }
                        Task { @MainActor in onChapterCompleted(event) }
                    }
                        )
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            if let requestedChapterPositions {
                let envelope = try JSONDecoder().decode(Envelope.self, from: manifest)
                guard envelope.manifest.chapters.count == requestedChapterPositions.count else {
                    throw EmbeddedConverterError.conversionFailed(
                        "Rust converted \(envelope.manifest.chapters.count) chapters; " +
                            "the request selected \(requestedChapterPositions.count)."
                    )
                }
            }
            try? appendLogLine("[Rust] conversion finished", to: logURL)
            return Result(jobID: jobID, manifestJSON: manifest, outputDirectory: outputDirectory)
        } catch {
            try? appendLogLine("[Rust] conversion failed: \(error.localizedDescription)", to: logURL)
            throw error
        }
    }

    func appendLogLine(_ line: String, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func convertFirstSubstantiveChapter(
        of bookURL: URL,
        minimumCharacters: Int = 2_500,
        jobID: String = UUID().uuidString,
        onChapterCompleted: (@MainActor @Sendable (ChapterCompletionEvent) -> Void)? = nil
    ) async throws -> Result {
        let book = try adapter.openBook(at: bookURL)
        guard
            let metadata = try JSONSerialization.jsonObject(with: book.metadataJSON) as? [String: Any],
            let chapters = metadata["chapters"] as? [[String: Any]]
        else {
            throw EmbeddedConverterError.conversionFailed(
                "Rust chapter metadata is missing or invalid."
            )
        }

        for (position, chapter) in chapters.enumerated() {
            guard (chapter["textChars"] as? Int ?? 0) >= minimumCharacters,
                  !isFrontMatter(title: chapter["name"] as? String ?? ""),
                  let selector = Int32(exactly: position) else {
                continue
            }
            return try await convert(
                bookURL: bookURL,
                jobID: jobID,
                chapterStart: selector,
                chapterEnd: selector,
                onChapterCompleted: onChapterCompleted
            )
        }

        throw EmbeddedConverterError.conversionFailed(
            "No substantive chapter can be selected unambiguously for a one-chapter test."
        )
    }

    private func isFrontMatter(title: String) -> Bool {
        let normalized = title.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return [
            "contents", "copyright", "credits", "table of contents", "folha de rosto",
            "sumario", "indice", "epigraph", "note on", "foreword", "title page", "cover",
            "preface", "dedication",
        ].contains(where: normalized.contains)
    }

    private func validateChapterSelection(
        in bookURL: URL,
        requestedPositions: ClosedRange<Int>
    ) throws {
        let book = try adapter.openBook(at: bookURL)
        guard
            let metadata = try JSONSerialization.jsonObject(with: book.metadataJSON) as? [String: Any],
            let chapters = metadata["chapters"] as? [[String: Any]]
        else {
            throw EmbeddedConverterError.conversionFailed(
                "Rust chapter metadata is missing or invalid."
            )
        }
        guard requestedPositions.upperBound < chapters.count else {
            throw EmbeddedConverterError.conversionFailed(
                "The selected Rust chapter range exceeds the EPUB chapter count."
            )
        }
    }

    private func requestedChapterRange(chapterStart: Int32, chapterEnd: Int32) -> ClosedRange<Int>? {
        guard chapterStart >= 0 else { return nil }
        let start = Int(chapterStart)
        let end = Int(chapterEnd)
        guard end >= start else { return start...start }
        return start...end
    }
}
