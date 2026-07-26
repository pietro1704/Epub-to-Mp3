import Foundation

/// Converts a library book through the embedded Python pipeline and exposes
/// the result in the same JobSnapshot shape used by the network backend.
/// This keeps the player independent from the selected conversion provider.
enum EmbeddedConversionCoordinator {
    @MainActor
    static func stream(
        bookURL: URL,
        bookID: String,
        engine: String = "edge",
        voice: String = "auto",
        language: String? = nil,
        clearCache: Bool = false,
        forceReprocess: Bool = false,
        maxPerformance: Bool = false,
        player: AudioPlayer
    ) async throws -> JobSnapshot {
        guard engine.lowercased() == "edge" else {
            return try await convert(
                bookURL: bookURL,
                bookID: bookID,
                engine: engine,
                voice: voice,
                language: language,
                clearCache: clearCache,
                forceReprocess: forceReprocess,
                maxPerformance: maxPerformance
            )
        }

        let payload = try await PythonBridge.shared.parseEpub(at: bookURL, bookId: bookID)
        let directories = try conversionDirectories(bookID: bookID)
        let narratable = payload.chapters.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !narratable.isEmpty else {
            throw PythonBridgeError.convertFailed("The book has no narratable chapters.")
        }

        let resolvedVoice = voice.lowercased() == "auto"
            ? VoiceSelector.edgeVoice(for: narratable[0].text, declaredLanguage: language)
            : voice
        let initial = snapshot(
            bookID: bookID,
            state: "running",
            title: payload.bookTitle,
            author: payload.bookAuthor,
            engine: engine,
            voice: resolvedVoice,
            language: language,
            chapters: narratable.map { chapter in
                JobSnapshot.Chapter(
                    index: chapter.index,
                    name: chapter.displayTitle,
                    status: "pending",
                    downloadUrl: nil,
                    chars: chapter.charCount,
                    charsProcessed: 0,
                    progressRatio: 0,
                    durationSeconds: nil,
                    startedAt: nil,
                    completedAt: nil
                )
            },
            total: narratable.count,
            error: nil
        )
        player.clearConversionState()
        player.isConverting = true
        player.play(snapshot: initial)

        var completed: [JobSnapshot.Chapter] = []
        var errors: [String] = []
        for chapter in narratable {
            do {
                let output = try await PythonBridge.shared.convertChapterStreaming(
                    text: chapter.text,
                    voice: resolvedVoice,
                    outputDir: directories.output,
                    chapterIndex: chapter.zeroBasedEpubIndex
                ) { data, chapterIndex, segmentIndex in
                    player.enqueueSegment(
                        data: data,
                        chapterIndex: chapterIndex,
                        segmentIndex: segmentIndex
                    )
                }
                completed.append(
                    JobSnapshot.Chapter(
                        index: chapter.index,
                        name: chapter.displayTitle,
                        status: "completed",
                        downloadUrl: output.absoluteString,
                        chars: chapter.charCount,
                        charsProcessed: chapter.charCount,
                        progressRatio: 1,
                        durationSeconds: nil,
                        startedAt: nil,
                        completedAt: Date().timeIntervalSince1970
                    )
                )
            } catch {
                errors.append("Chapter \(chapter.index): \(error.localizedDescription)")
            }
        }

        guard !completed.isEmpty else {
            player.isConverting = false
            throw PythonBridgeError.convertFailed(errors.joined(separator: "\n"))
        }
        let final = snapshot(
            bookID: bookID,
            state: errors.isEmpty ? "finished" : "failed",
            title: payload.bookTitle,
            author: payload.bookAuthor,
            engine: engine,
            voice: resolvedVoice,
            language: language,
            chapters: completed,
            total: narratable.count,
            error: errors.isEmpty ? nil : errors.joined(separator: "\n")
        )
        player.finishEmbeddedStreaming(snapshot: final)
        return final
    }

    static func convert(
        bookURL: URL,
        bookID: String,
        engine: String = "edge",
        voice: String = "auto",
        language: String? = nil,
        clearCache: Bool = false,
        forceReprocess: Bool = false,
        maxPerformance: Bool = false
    ) async throws -> JobSnapshot {
        let directories = try conversionDirectories(bookID: bookID)
        var options = PythonBridge.ConvertOptions()
        options.engine = engine
        options.voice = voice
        options.language = language
        options.clearCache = clearCache
        options.forceReprocess = forceReprocess
        options.maxPerformance = maxPerformance

        let result = try await PythonBridge.shared.convertEpub(
            epubURL: bookURL,
            outputDir: directories.output,
            cacheDir: directories.cache,
            voice: voice,
            options: options
        )
        let manifestsByFilename = Dictionary(
            result.manifest.compactMap { manifest -> (String, PythonBridge.ChapterEntry)? in
                guard let outputPath = manifest.outputPath else { return nil }
                return (URL(fileURLWithPath: outputPath).lastPathComponent, manifest)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let playable = result.outputs.enumerated().map { offset, url in
            let manifest = manifestsByFilename[url.lastPathComponent] ?? result.manifest[safe: offset]
            return JobSnapshot.Chapter(
                index: offset,
                name: manifest?.name,
                status: "completed",
                downloadUrl: url.absoluteString,
                chars: manifest?.charCount,
                charsProcessed: manifest?.charCount,
                progressRatio: 1,
                durationSeconds: nil,
                startedAt: nil,
                completedAt: nil
            )
        }
        guard !playable.isEmpty else {
            let details = result.errors.joined(separator: "\n")
            throw PythonBridgeError.convertFailed(
                details.isEmpty ? "Embedded conversion produced no audio." : details
            )
        }

        return JobSnapshot(
            jobId: jobID(for: bookID),
            state: result.errors.isEmpty ? "finished" : "running",
            bookTitle: result.bookTitle,
            bookAuthor: result.bookAuthor,
            coverUrl: nil,
            coverMimeType: nil,
            engine: engine,
            voice: voice,
            language: language,
            progressPercent: Double(playable.count) / Double(max(1, result.manifest.count)) * 100,
            chaptersTotal: result.manifest.count,
            chaptersCompleted: playable.count,
            chapterProgress: playable,
            outputs: nil,
            logUrl: nil,
            error: result.errors.isEmpty ? nil : result.errors.joined(separator: "\n"),
            lastActivityAt: Date().timeIntervalSince1970
        )
    }

    static func jobID(for bookID: String) -> String {
        "embedded-\(bookID)"
    }

    private static func snapshot(
        bookID: String,
        state: String,
        title: String?,
        author: String?,
        engine: String,
        voice: String,
        language: String?,
        chapters: [JobSnapshot.Chapter],
        total: Int,
        error: String?
    ) -> JobSnapshot {
        JobSnapshot(
            jobId: jobID(for: bookID),
            state: state,
            bookTitle: title,
            bookAuthor: author,
            coverUrl: nil,
            coverMimeType: nil,
            engine: engine,
            voice: voice,
            language: language,
            progressPercent: Double(chapters.count) / Double(max(1, total)) * 100,
            chaptersTotal: total,
            chaptersCompleted: chapters.count,
            chapterProgress: chapters,
            outputs: nil,
            logUrl: nil,
            error: error,
            lastActivityAt: Date().timeIntervalSince1970
        )
    }

    private static func conversionDirectories(bookID: String) throws -> (output: URL, cache: URL) {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bookRoot = root
            .appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("EmbeddedConversion", isDirectory: true)
            .appendingPathComponent(bookID, isDirectory: true)
        let output = bookRoot.appendingPathComponent("output", isDirectory: true)
        let cache = bookRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return (output, cache)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
