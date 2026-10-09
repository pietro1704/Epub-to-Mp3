import Foundation

private let rustConversionQueue = DispatchQueue(label: "com.pietrocode.epubtomp3.rust-conversion", qos: .userInitiated)

private struct RustConversionInvocation: @unchecked Sendable {
    let adapter: ConverterFFIAdapter
}

extension RustConversionCoordinator.ChapterCompletionEvent {
    private enum CodingKeys: String, CodingKey {
        case jobId, bookTitle, bookAuthor, chapterIndex, chaptersTotal, chaptersCompleted
        case chapterTitle, filename, audioPath, textChars
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
        let path = try values.decode(String.self, forKey: .audioPath)
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw DecodingError.dataCorruptedError(forKey: .audioPath, in: values,
                                                  debugDescription: "Chapter audio requires an absolute local file path.")
        }
        // Rust serializes a filesystem path, not a URI. Preserve literal #, ? and %.
        audioPath = URL(fileURLWithPath: path)
    }
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
                // Chapter events do not carry resolved provider configuration.
                engine: nil,
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

        func validateSelectedChapters(_ positions: ClosedRange<Int>) throws {
            let envelope = try JSONDecoder().decode(Envelope.self, from: manifestJSON)
            guard envelope.manifest.jobId == jobID else {
                throw EmbeddedConverterError.conversionFailed("Rust returned a different conversion job ID.")
            }
            // Count alone cannot distinguish the requested chapters from an
            // equally sized, duplicated or reordered selection. Scoped jobs
            // require the explicit source identity emitted by the Rust worker.
            let actual = envelope.manifest.chapters.map(\.sourceIndex)
            let expected = positions.map { Optional($0) }
            guard actual == expected else {
                throw EmbeddedConverterError.conversionFailed(
                    "Rust chapter identities do not match the selected range \(positions.lowerBound)...\(positions.upperBound)."
                )
            }
        }

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

    typealias Executor = @MainActor (
        URL, String, Int32, Int32,
        (@MainActor @Sendable (ConversionProgressEvent) -> Void)?,
        (@MainActor @Sendable (ChapterCompletionEvent) -> Void)?
    ) async throws -> Result

    @MainActor
    static func execute(bookURL: URL, jobID: String, chapterStart: Int32, chapterEnd: Int32,
                        onProgress: (@MainActor @Sendable (ConversionProgressEvent) -> Void)?,
                        onChapterCompleted: (@MainActor @Sendable (ChapterCompletionEvent) -> Void)?) async throws -> Result {
        try await RustConversionCoordinator().convert(bookURL: bookURL, jobID: jobID,
            chapterStart: chapterStart, chapterEnd: chapterEnd,
            onProgress: onProgress, onChapterCompleted: onChapterCompleted)
    }

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
        options: ConversionOptions? = nil,
        onProgress: (@MainActor @Sendable (ConversionProgressEvent) -> Void)? = nil,
        onChapterCompleted: (@MainActor @Sendable (ChapterCompletionEvent) -> Void)? = nil
    ) async throws -> Result {
        if options != nil {
            try adapter.validateConversionSupport(options: options)
        }
        let requestedChapterPositions = try requestedChapterRange(
            in: bookURL,
            chapterStart: chapterStart,
            chapterEnd: chapterEnd
        )
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
                    options: options,
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
            let result = Result(jobID: jobID, manifestJSON: manifest, outputDirectory: outputDirectory)
            if let requestedChapterPositions {
                try result.validateSelectedChapters(requestedChapterPositions)
            }
            try? appendLogLine("[Rust] conversion finished", to: logURL)
            return result
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
        options: ConversionOptions? = nil,
        onChapterCompleted: (@MainActor @Sendable (ChapterCompletionEvent) -> Void)? = nil
    ) async throws -> Result {
        if options != nil {
            try adapter.validateConversionSupport(options: options)
        }
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
                options: options,
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

    private func requestedChapterRange(
        in bookURL: URL,
        chapterStart: Int32,
        chapterEnd: Int32
    ) throws -> ClosedRange<Int>? {
        do {
            try ConversionChapterSelection.validateBounds(start: chapterStart, end: chapterEnd)
        } catch {
            throw EmbeddedConverterError.conversionFailed("Invalid Rust chapter selection.")
        }
        if chapterStart == -1 && chapterEnd == -1 { return nil }
        let book = try adapter.openBook(at: bookURL)
        guard
            let metadata = try JSONSerialization.jsonObject(with: book.metadataJSON) as? [String: Any],
            let chapters = metadata["chapters"] as? [[String: Any]]
        else {
            throw EmbeddedConverterError.conversionFailed(
                "Rust chapter metadata is missing or invalid."
            )
        }
        do {
            return try ConversionChapterSelection.resolve(start: chapterStart, end: chapterEnd,
                                                          chapterCount: chapters.count)
        } catch {
            throw EmbeddedConverterError.conversionFailed(
                "The selected Rust chapter range exceeds the EPUB chapter count."
            )
        }
    }
}
