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
        player: AudioPlayer,
        onStreamingStarted: @MainActor @escaping () -> Void = {}
    ) async throws -> JobSnapshot {
        guard engine.lowercased() == "edge" else {
            let converted = try await convert(
                bookURL: bookURL,
                bookID: bookID,
                engine: engine,
                voice: voice,
                language: language,
                clearCache: clearCache,
                forceReprocess: forceReprocess,
                maxPerformance: maxPerformance
            )
            player.clearConversionState()
            player.isConverting = false
            player.play(snapshot: converted)
            player.resume()
            onStreamingStarted()
            return converted
        }

        let payload = try await PythonBridge.shared.parseEpub(at: bookURL, bookId: bookID)
        LocalFulltextCache.save(payload, bookId: bookID)
        player.updateReaderChapterTitles(payload.chapters)
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
            completedCount: 0,
            error: nil
        )
        player.clearConversionState()
        player.isConverting = true
        player.play(snapshot: initial)
        // Tapping Listen is explicit user intent. Arm playback now so the
        // first streamed segment starts immediately instead of remaining
        // paused behind a spinner until the user taps a second time.
        player.resume()
        onStreamingStarted()

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
                let live = liveSnapshot(
                    bookID: bookID,
                    title: payload.bookTitle,
                    author: payload.bookAuthor,
                    engine: engine,
                    voice: resolvedVoice,
                    language: language,
                    narratable: narratable,
                    completed: completed,
                    errors: errors
                )
                player.updateSnapshot(live)
                save(snapshot: live, bookID: bookID)
            } catch {
                errors.append("Chapter \(chapter.index): \(error.localizedDescription)")
                let live = liveSnapshot(
                    bookID: bookID,
                    title: payload.bookTitle,
                    author: payload.bookAuthor,
                    engine: engine,
                    voice: resolvedVoice,
                    language: language,
                    narratable: narratable,
                    completed: completed,
                    errors: errors
                )
                player.updateSnapshot(live)
                save(snapshot: live, bookID: bookID)
            }
        }

        guard !completed.isEmpty else {
            player.isConverting = false
            throw PythonBridgeError.convertFailed(errors.joined(separator: "\n"))
        }
        let final = liveSnapshot(
            bookID: bookID,
            title: payload.bookTitle,
            author: payload.bookAuthor,
            engine: engine,
            voice: resolvedVoice,
            language: language,
            narratable: narratable,
            completed: completed,
            errors: errors,
            state: errors.isEmpty ? "finished" : "failed"
        )
        player.finishEmbeddedStreaming(snapshot: final)
        save(snapshot: final, bookID: bookID)
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

        let snapshot = JobSnapshot(
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
        save(snapshot: snapshot, bookID: bookID)
        return snapshot
    }

    static func jobID(for bookID: String) -> String {
        "embedded-\(bookID)"
    }

    static func loadSnapshot(bookID: String) -> JobSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey(bookID: bookID)) else {
            return nil
        }
        guard let snapshot = try? JSONDecoder().decode(JobSnapshot.self, from: data) else {
            return nil
        }
        guard let fulltext = LocalFulltextCache.read(bookId: bookID) else {
            return snapshot
        }
        let reconciled = reconciledSnapshot(snapshot, fulltext: fulltext)
        if reconciled != snapshot {
            save(snapshot: reconciled, bookID: bookID)
        }
        return reconciled
    }

    /// Repairs older embedded snapshots which predate canonical TOC titles.
    /// The fulltext cache is parsed from the same book and therefore wins
    /// only when the saved chapter label is blank or a generic number.
    static func reconciledSnapshot(
        _ snapshot: JobSnapshot,
        fulltext: EbookFulltext
    ) -> JobSnapshot {
        guard let chapterProgress = snapshot.chapterProgress, !chapterProgress.isEmpty else {
            return snapshot
        }
        var titlesByEpubIndex: [Int: String] = [:]
        for chapter in fulltext.chapters {
            titlesByEpubIndex[chapter.index] = chapter.displayTitle
        }
        let usesZeroBasedIndices = chapterProgress.contains { $0.index == 0 }
        var reconciled = snapshot
        reconciled.chapterProgress = chapterProgress.map { chapter in
            let epubIndex = usesZeroBasedIndices ? chapter.index + 1 : chapter.index
            guard needsTitleRepair(chapter.name),
                  let title = titlesByEpubIndex[epubIndex],
                  !AudioPlayer.isGenericChapterTitle(title) else {
                return chapter
            }
            var repaired = chapter
            repaired.name = title
            return repaired
        }
        return reconciled
    }

    private static func needsTitleRepair(_ title: String?) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return true
        }
        return AudioPlayer.isGenericChapterTitle(title)
    }

    private static func save(snapshot: JobSnapshot, bookID: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: snapshotKey(bookID: bookID))
    }

    private static func snapshotKey(bookID: String) -> String {
        "embeddedConversion.snapshot.\(bookID)"
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
        completedCount: Int? = nil,
        error: String?
    ) -> JobSnapshot {
        let resolvedCompletedCount = completedCount ?? chapters.count
        return JobSnapshot(
            jobId: jobID(for: bookID),
            state: state,
            bookTitle: title,
            bookAuthor: author,
            coverUrl: nil,
            coverMimeType: nil,
            engine: engine,
            voice: voice,
            language: language,
            progressPercent: Double(resolvedCompletedCount) / Double(max(1, total)) * 100,
            chaptersTotal: total,
            chaptersCompleted: resolvedCompletedCount,
            chapterProgress: chapters,
            outputs: nil,
            logUrl: nil,
            error: error,
            lastActivityAt: Date().timeIntervalSince1970
        )
    }

    static func liveSnapshot(
        bookID: String,
        title: String?,
        author: String?,
        engine: String,
        voice: String,
        language: String?,
        narratable: [EbookFulltext.Chapter],
        completed: [JobSnapshot.Chapter],
        errors: [String],
        state: String = "running"
    ) -> JobSnapshot {
        let completedByIndex = Dictionary(uniqueKeysWithValues: completed.map { ($0.index, $0) })
        let failedIndices = Set(errors.compactMap { error -> Int? in
            let prefix = "Chapter "
            guard error.hasPrefix(prefix) else { return nil }
            let number = error.dropFirst(prefix.count).prefix { $0.isNumber }
            return Int(number)
        })
        let chapters = narratable.map { chapter -> JobSnapshot.Chapter in
            if let completed = completedByIndex[chapter.index] {
                return completed
            }
            return JobSnapshot.Chapter(
                index: chapter.index,
                name: chapter.displayTitle,
                status: failedIndices.contains(chapter.index) ? "failed" : "pending",
                downloadUrl: nil,
                chars: chapter.charCount,
                charsProcessed: 0,
                progressRatio: 0,
                durationSeconds: nil,
                startedAt: nil,
                completedAt: nil
            )
        }
        return snapshot(
            bookID: bookID,
            state: state,
            title: title,
            author: author,
            engine: engine,
            voice: voice,
            language: language,
            chapters: chapters,
            total: narratable.count,
            completedCount: completed.count,
            error: errors.isEmpty ? nil : errors.joined(separator: "\n")
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
