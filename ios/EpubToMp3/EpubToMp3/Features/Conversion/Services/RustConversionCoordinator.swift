import Foundation

private struct RustConversionInvocation: @unchecked Sendable {
    let adapter: ConverterFFIAdapter
}

/// Local conversion entry point shared by the Apple clients.
///
/// This type deliberately has no transport or backend dependency. The Rust
/// FFI owns EPUB parsing, model selection, conversion, and artifact creation.
final class RustConversionCoordinator {
    private let adapter: ConverterFFIAdapter
    private let fileManager: FileManager
    private let outputStore: RustConversionOutputStore
    private let recoveryStore: BookConversionRecoveryStore

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

    init(
        adapter: ConverterFFIAdapter = ConverterFFIAdapter(),
        fileManager: FileManager = .default,
        outputStore: RustConversionOutputStore = .shared,
        recoveryStore: BookConversionRecoveryStore? = nil
    ) {
        self.adapter = adapter
        self.fileManager = fileManager
        self.outputStore = outputStore
        self.recoveryStore = recoveryStore ?? (outputStore === RustConversionOutputStore.shared
            ? .shared : BookConversionRecoveryStore(root: outputStore.recoveryRoot))
    }

    func convert(
        bookURL: URL,
        jobID: String = UUID().uuidString,
        chapterStart: Int32 = -1,
        chapterEnd: Int32 = -1,
        options requestedOptions: ConversionOptions? = nil,
        playbackControl: ConverterPlaybackControl? = nil,
        onProgress: (@MainActor @Sendable (ConversionProgressEvent) -> Void)? = nil,
        onChapterCompleted: (@MainActor @Sendable (ChapterCompletionEvent) -> Void)? = nil,
        onAudioChunk: (@Sendable (Int, Int, Data) -> Bool)? = nil,
        readerChapterMap: ReaderConversionChapterMap? = nil
    ) async throws -> Result {
        // Reject invalid explicit options before reading book bytes or prefs.
        if requestedOptions != nil {
            try adapter.validateConversionSupport(options: requestedOptions)
        }
        var options = requestedOptions
        if options?.pronunciation == nil {
            let bookID = try await Task.detached { try BookContentIdentity.hash(of: bookURL) }.value
            let dictionary = BookPronunciationStore().load(bookID: bookID)
            if !dictionary.rules.isEmpty {
                var captured = options ?? ConversionOptions()
                captured.pronunciation = dictionary
                options = captured
            }
        }
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
        let recoveryStore = self.recoveryStore
        let recoveryBookID: String?
        do {
            recoveryBookID = playbackControl == nil && chapterStart < 0 && chapterEnd < 0
                ? try await recoveryStore.begin(bookURL: bookURL, jobID: jobID, options: options)
                : nil
        } catch {
            await outputStore.finish(lease)
            throw error
        }

        do {
            try Task.checkCancellation()
            if let readerChapterMap {
                // Persist before Rust can publish artifacts, while this job
                // still owns its output lease. Interrupted jobs retain the axis.
                try JSONEncoder().encode(readerChapterMap).write(
                    to: outputDirectory.appendingPathComponent("reader-chapter-map.json"), options: .atomic
                )
            }
            try? appendLogLine("[Rust] conversion started: \(bookURL.lastPathComponent)", to: logURL)
            let manifest = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let invocation = RustConversionInvocation(adapter: self.adapter)
                    RustConversionWorkQueues.shared.enqueue(for: playbackControl == nil ? .manual : .listening) { [options] in
                        do {
                            guard !effectiveControl.isCancellationRequested else { throw CancellationError() }
                            let data = try invocation.adapter.convertBook(
                                at: bookURL,
                                outputDirectory: outputDirectory,
                                jobID: jobID,
                                chapterStart: chapterStart,
                                chapterEnd: chapterEnd,
                                options: options,
                                playbackControl: effectiveControl,
                                onProgress: { data in
                                    guard let event = try? JSONDecoder().decode(
                                            ConversionProgressEvent.self,
                                            from: try readerChapterMap?.event(data) ?? data
                                          ) else {
                                        return
                                    }
                                    Task { @MainActor in
                                        if let recoveryBookID {
                                            try? await recoveryStore.progress(
                                                bookID: recoveryBookID, jobID: jobID, total: event.chaptersTotal)
                                        }
                                        onProgress?(event)
                                    }
                                },
                                onChapterCompleted: { data in
                                    guard let event = try? JSONDecoder().decode(
                                            ChapterCompletionEvent.self,
                                            from: try readerChapterMap?.event(data) ?? data
                                          ) else {
                                        return
                                    }
                                    Task { @MainActor in
                                        if let recoveryBookID {
                                            try? await recoveryStore.progress(
                                                bookID: recoveryBookID, jobID: jobID, total: event.chaptersTotal,
                                                completed: event.chapterIndex)
                                        }
                                        onChapterCompleted?(event)
                                    }
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
            _ = try result.snapshot()
            if let requestedChapterPositions {
                try result.validateSelectedChapters(requestedChapterPositions)
            }
            try? appendLogLine("[Rust] conversion finished", to: logURL)
            if let recoveryBookID {
                try await recoveryStore.finish(bookID: recoveryBookID, jobID: jobID, succeeded: true)
            }
            await outputStore.finish(lease)
            return result
        } catch {
            if let recoveryBookID {
                try? await recoveryStore.finish(bookID: recoveryBookID, jobID: jobID, succeeded: false)
            }
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
