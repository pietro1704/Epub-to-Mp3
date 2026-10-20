import Foundation

private let rustConversionQueue = DispatchQueue(label: "com.pietrocode.epubtomp3.rust-conversion", qos: .userInitiated)

private struct RustConversionInvocation: @unchecked Sendable {
    let adapter: ConverterFFIAdapter
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

/// Local conversion entry point shared by the Apple clients.
///
/// This type deliberately has no transport or backend dependency. The Rust
/// FFI owns EPUB parsing, model selection, conversion, and artifact creation.
final class RustConversionCoordinator {
    /// Restore durable Rust output without reopening or synthesizing the book.
    static func persistedSnapshot(jobID: String, fileManager: FileManager = .default) -> JobSnapshot? {
        guard !jobID.isEmpty, jobID != ".", jobID != "..",
              !jobID.contains("/"), !jobID.contains("\\"), !jobID.contains("\0"),
              let root = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: false) else { return nil }
        let directory = root.appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("RustConversions", isDirectory: true)
            .appendingPathComponent(jobID, isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.jobId == jobID, !manifest.chapters.isEmpty else { return nil }
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var indices = Set<Int>()
        for (offset, chapter) in manifest.chapters.enumerated() {
            let index = chapter.sourceIndex ?? offset
            guard index >= 0, indices.insert(index).inserted,
                  !chapter.filename.isEmpty, !chapter.filename.hasPrefix("/"),
                  !chapter.filename.contains("\0") else { return nil }
            let url = directory.appendingPathComponent(chapter.filename).resolvingSymlinksInPath()
            guard url.standardizedFileURL.path.hasPrefix(directoryPath),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { return nil }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = try? JSONSerialization.data(withJSONObject: ["manifest": object]) else { return nil }
        return try? Result(jobID: jobID, manifestJSON: envelope, outputDirectory: directory).snapshot()
    }

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
                engine: envelope.manifest.usedSelections.map { Array(Set($0.map(\.engine))).sorted().joined(separator: " + ") },
                voice: envelope.manifest.usedSelections.map { $0.compactMap { $0.modelID ?? $0.voice }.joined(separator: " + ") },
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
        let ttsPreferences: TtsPreferences?
        let usedSelections: [TtsSelection]?
    }
    private struct Chapter: Decodable {
        let title: String?
        let filename: String
        let textChars: Int
        let sourceIndex: Int?
    }

    private let adapter: ConverterFFIAdapter
    private let fileManager: FileManager
    private let outputStore: RustConversionOutputStore

    typealias Executor = @MainActor (
        URL, String, Int32, Int32, ConversionOptions?,
        (@MainActor @Sendable (ConversionProgressEvent) -> Void)?,
        (@MainActor @Sendable (ChapterCompletionEvent) -> Void)?
    ) async throws -> Result

    typealias StreamingExecutor = @MainActor (
        URL, String, Int32, Int32, ConverterPlaybackControl, ConversionOptions?,
        (@MainActor @Sendable (ConversionProgressEvent) -> Void)?,
        (@MainActor @Sendable (ChapterCompletionEvent) -> Void)?,
        (@Sendable (Int, Int, Data) -> Bool)?
    ) async throws -> Result

    @MainActor
    static func execute(bookURL: URL, jobID: String, chapterStart: Int32, chapterEnd: Int32,
                        options: ConversionOptions? = nil,
                        onProgress: (@MainActor @Sendable (ConversionProgressEvent) -> Void)?,
                        onChapterCompleted: (@MainActor @Sendable (ChapterCompletionEvent) -> Void)?) async throws -> Result {
        try await RustConversionCoordinator().convert(bookURL: bookURL, jobID: jobID,
            chapterStart: chapterStart, chapterEnd: chapterEnd,
            options: options,
            onProgress: onProgress, onChapterCompleted: onChapterCompleted)
    }

    @MainActor
    static func makePlaybackControl() throws -> ConverterPlaybackControl {
        try ConverterFFIAdapter().makePlaybackControl()
    }

    @MainActor
    static func executeStreaming(
        bookURL: URL,
        jobID: String,
        chapterStart: Int32,
        chapterEnd: Int32,
        control: ConverterPlaybackControl,
        options: ConversionOptions? = nil,
        onProgress: (@MainActor @Sendable (ConversionProgressEvent) -> Void)?,
        onChapterCompleted: (@MainActor @Sendable (ChapterCompletionEvent) -> Void)?,
        onAudioChunk: (@Sendable (Int, Int, Data) -> Bool)?
    ) async throws -> Result {
        try await RustConversionCoordinator().convert(
            bookURL: bookURL,
            jobID: jobID,
            chapterStart: chapterStart,
            chapterEnd: chapterEnd,
            options: options,
            playbackControl: control,
            onProgress: onProgress,
            onChapterCompleted: onChapterCompleted,
            onAudioChunk: onAudioChunk
        )
    }

    init(
        adapter: ConverterFFIAdapter = ConverterFFIAdapter(),
        fileManager: FileManager = .default,
        outputStore: RustConversionOutputStore = .shared
    ) {
        self.adapter = adapter
        self.fileManager = fileManager
        self.outputStore = outputStore
    }

    func convert(
        bookURL: URL,
        jobID: String = UUID().uuidString,
        chapterStart: Int32 = -1,
        chapterEnd: Int32 = -1,
        options: ConversionOptions? = nil,
        playbackControl: ConverterPlaybackControl? = nil,
        onProgress: (@MainActor @Sendable (ConversionProgressEvent) -> Void)? = nil,
        onChapterCompleted: (@MainActor @Sendable (ChapterCompletionEvent) -> Void)? = nil,
        onAudioChunk: (@Sendable (Int, Int, Data) -> Bool)? = nil
    ) async throws -> Result {
        if options != nil {
            try adapter.validateConversionSupport(options: options)
        }
        let requestedChapterPositions = try requestedChapterRange(
            in: bookURL,
            chapterStart: chapterStart,
            chapterEnd: chapterEnd
        )
        let effectiveControl: ConverterPlaybackControl
        if let playbackControl {
            effectiveControl = playbackControl
        } else {
            effectiveControl = try await Self.makePlaybackControl()
        }
        let lease = try await outputStore.begin(bookURL: bookURL, jobID: jobID,
                                               cancel: { effectiveControl.cancel() })
        let outputDirectory = lease.outputDirectory
        let logURL = outputDirectory.appendingPathComponent("conversion.log")

        do {
            try Task.checkCancellation()
            try? appendLogLine("[Rust] conversion started: \(bookURL.lastPathComponent)", to: logURL)
            let manifest = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
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
                                playbackControl: effectiveControl,
                                onProgress: { data in
                                    guard let onProgress,
                                          let event = try? JSONDecoder().decode(
                                            ConversionProgressEvent.self,
                                            from: data
                                          ) else {
                                        return
                                    }
                                    Task { @MainActor in onProgress(event) }
                                },
                                onChapterCompleted: { data in
                                    guard let onChapterCompleted,
                                          let event = try? JSONDecoder().decode(
                                            ChapterCompletionEvent.self,
                                            from: data
                                          ) else {
                                        return
                                    }
                                    Task { @MainActor in onChapterCompleted(event) }
                                },
                                onAudioChunk: onAudioChunk
                            )
                            continuation.resume(returning: data)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }, onCancel: { effectiveControl.cancel() })
            try Task.checkCancellation()
            let result = Result(jobID: jobID, manifestJSON: manifest, outputDirectory: outputDirectory)
            if let requestedChapterPositions {
                try result.validateSelectedChapters(requestedChapterPositions)
            }
            try? appendLogLine("[Rust] conversion finished", to: logURL)
            await outputStore.finish(lease)
            return result
        } catch {
            try? appendLogLine("[Rust] conversion failed: \(error.localizedDescription)", to: logURL)
            await outputStore.finish(lease)
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
