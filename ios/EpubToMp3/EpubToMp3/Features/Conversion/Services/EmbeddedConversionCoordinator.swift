import Foundation

@MainActor
private final class SegmentEmission {
    var didEmit = false
}

/// Converts a library book through the embedded Python pipeline and exposes
/// the result in the same JobSnapshot shape used by the network backend.
/// This keeps the player independent from the selected conversion provider.
enum EmbeddedConversionCoordinator {
    static let maximumAutomaticChapterAttempts = 2

    enum LocalCacheAction: Equatable {
        case reuse
        case regenerateOutputs
        case clearBook
    }

    enum StreamingMode: Equatable {
        case lowestLatencySerial
        case orderedParallel
    }

    private struct StreamRequest: Equatable {
        let bookID: String
        let engine: String
        let voice: String
        let language: String?
        let clearCache: Bool
        let forceReprocess: Bool
        let maxPerformance: Bool
        let priorityChapterIndices: [Int]
        let requestedChapterIndices: [Int]?
    }

    @MainActor
    private final class StreamLease {
        final class PlaybackAttachment {
            let player: AudioPlayer
            let autoPlay: Bool
            let priorityChapterIndices: [Int]
            let onStreamingStarted: @MainActor () -> Void
            let onChapterAvailable: @MainActor (JobSnapshot.Chapter) -> Void
            var hasBegun = false

            init(
                player: AudioPlayer,
                autoPlay: Bool,
                priorityChapterIndices: [Int],
                onStreamingStarted: @escaping @MainActor () -> Void,
                onChapterAvailable: @escaping @MainActor (JobSnapshot.Chapter) -> Void
            ) {
                self.player = player
                self.autoPlay = autoPlay
                self.priorityChapterIndices = priorityChapterIndices
                self.onStreamingStarted = onStreamingStarted
                self.onChapterAvailable = onChapterAvailable
            }
        }

        let id = UUID()
        let request: StreamRequest
        let drivesPlayer: Bool
        weak var player: AudioPlayer?
        var task: Task<JobSnapshot, Error>?
        var playbackAttachment: PlaybackAttachment?

        var ownsPlayback: Bool {
            drivesPlayer || playbackAttachment?.hasBegun == true
        }

        init(request: StreamRequest, drivesPlayer: Bool, player: AudioPlayer) {
            self.request = request
            self.drivesPlayer = drivesPlayer
            self.player = player
        }
    }

    @MainActor private static var activeStream: StreamLease?

    /// Starts the requested chapter from the canonical local artifact store
    /// without resolving the EPUB bookmark or booting Python. `nil` means the
    /// requested chapter is not local and the regular conversion path should
    /// run. A partial snapshot keeps the player ready while its missing
    /// chapters continue converting in the background.
    @MainActor
    static func resumeLocalPlaybackIfAvailable(
        bookID: String,
        engine: String = "edge",
        voice: String = "auto",
        language: String? = nil,
        priorityChapterIndices: [Int],
        autoPlay: Bool = true,
        player: AudioPlayer
    ) async -> JobSnapshot? {
        guard let snapshot = try? await LocalAudioArtifactStore.shared.playableSnapshot(
            bookID: bookID,
            engine: engine,
            voice: voice,
            language: language
        ), let startingAt = snapshot.playableChapters.firstIndex(where: {
            priorityChapterIndices.contains($0.index)
        }) else {
            return nil
        }
        player.stop()
        player.clearConversionState()
        player.isConverting = snapshot.state == "partial"
        player.play(snapshot: snapshot, startingAt: startingAt)
        if autoPlay { player.resume() }
        return snapshot
    }

    /// Continues a partially local audiobook without replacing the queue that
    /// is already playing. Each generated chapter is projected from the
    /// canonical artifact manifest and appended by `AudioPlayer`.
    @MainActor
    static func continuePartialLocalPlayback(
        bookURL: URL,
        bookID: String,
        engine: String = "edge",
        voice: String = "auto",
        language: String? = nil,
        clearCache: Bool = false,
        forceReprocess: Bool = false,
        maxPerformance: Bool = false,
        requiresWiFi: Bool = true,
        priorityChapterIndices: [Int],
        requestedChapterIndices: [Int]? = nil,
        player: AudioPlayer,
        resumeRequest: LocalAudioConversionScheduler.ResumeRequest? = nil,
        onChapterAvailable: @MainActor @escaping (JobSnapshot.Chapter) -> Void = { _ in }
    ) async throws -> JobSnapshot {
        defer { player.isConverting = false }
        let completed = try await stream(
            bookURL: bookURL,
            bookID: bookID,
            engine: engine,
            voice: voice,
            language: language,
            clearCache: clearCache,
            forceReprocess: forceReprocess,
            maxPerformance: maxPerformance,
            autoPlay: false,
            requiresWiFi: requiresWiFi,
            priorityChapterIndices: priorityChapterIndices,
            requestedChapterIndices: requestedChapterIndices,
            drivesPlayer: false,
            player: player,
            resumeRequest: resumeRequest,
            onStreamingStarted: {},
            onChapterAvailable: { chapter in
                onChapterAvailable(chapter)
                Task { @MainActor in
                    if let refreshed = try? await LocalAudioArtifactStore.shared.playableSnapshot(
                        bookID: bookID,
                        engine: engine,
                        voice: voice,
                        language: language
                    ) {
                        player.updateSnapshot(refreshed)
                    }
                }
            }
        )
        player.updateSnapshot(completed)
        return completed
    }

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
        autoPlay: Bool = true,
        requiresWiFi: Bool = true,
        priorityChapterIndices: [Int] = [],
        requestedChapterIndices: [Int]? = nil,
        drivesPlayer: Bool = true,
        player: AudioPlayer,
        resumeRequest: LocalAudioConversionScheduler.ResumeRequest? = nil,
        onStreamingStarted: @MainActor @escaping () -> Void = {},
        onChapterAvailable: @MainActor @escaping (JobSnapshot.Chapter) -> Void = { _ in }
    ) async throws -> JobSnapshot {
        beginPlaybackPreparationIfNeeded(drivesPlayer: drivesPlayer, player: player)

        // Do not make a listener wait for Python startup, fulltext recovery,
        // or the remaining conversion when the chapter they asked for already
        // has a canonical local MP3. Start that chapter immediately, then run
        // the unfinished work as a background stream and append each newly
        // available artifact to the same player queue.
        if drivesPlayer,
           !clearCache,
           !forceReprocess,
           let locallyPlayable = await resumeLocalPlaybackIfAvailable(
                bookID: bookID,
                engine: engine,
                voice: voice,
                language: language,
                priorityChapterIndices: priorityChapterIndices,
                autoPlay: autoPlay,
                player: player
           ) {
            onStreamingStarted()
            guard locallyPlayable.state == "partial" else {
                return locallyPlayable
            }

            return try await continuePartialLocalPlayback(
                bookURL: bookURL,
                bookID: bookID,
                engine: engine,
                voice: voice,
                language: language,
                clearCache: clearCache,
                forceReprocess: forceReprocess,
                maxPerformance: maxPerformance,
                requiresWiFi: requiresWiFi,
                priorityChapterIndices: priorityChapterIndices,
                requestedChapterIndices: requestedChapterIndices,
                player: player,
                resumeRequest: resumeRequest,
                onChapterAvailable: { chapter in
                    onChapterAvailable(chapter)
                }
            )
        }

        // A whole-book download may already be converting this same book.
        // Do not cancel it or make the user wait for every remaining chapter:
        // at the next chapter boundary we attach the reader's player and move
        // its current chapter to the front of that book's pending work.
        if drivesPlayer,
           let active = activeStream,
           !active.drivesPlayer,
           active.request.requestedChapterIndices == nil,
           active.request.bookID == bookID,
           let task = active.task {
            active.playbackAttachment = StreamLease.PlaybackAttachment(
                player: player,
                autoPlay: autoPlay,
                priorityChapterIndices: priorityChapterIndices,
                onStreamingStarted: onStreamingStarted,
                onChapterAvailable: onChapterAvailable
            )
            LocalAudioConversionScheduler.shared.prioritize(
                bookID: bookID,
                chapterIndices: priorityChapterIndices
            )
            return try await task.value
        }
        let schedulingKey = resumeRequest?.coalescingKey ?? localSchedulingKey(
            drivesPlayer: drivesPlayer,
            requestedChapterIndices: requestedChapterIndices
        )
        let persistedRequest = resumeRequest ?? LocalAudioConversionScheduler.ResumeRequest(
            bookID: bookID,
            coalescingKey: schedulingKey,
            requiresWiFi: requiresWiFi,
            priorityChapterIndices: priorityChapterIndices,
            requestedChapterIndices: requestedChapterIndices,
            engine: engine,
            voice: voice,
            language: language,
            clearCache: clearCache,
            forceReprocess: forceReprocess,
            maxPerformance: maxPerformance
        )
        LocalAudioConversionScheduler.shared.setAllowsCellularConversion(!requiresWiFi)
        return try await LocalAudioConversionScheduler.shared.submit(
            bookID: bookID,
            requiresWiFi: requiresWiFi,
            priorityChapterIndices: priorityChapterIndices,
            coalescingKey: schedulingKey,
            resumeRequest: persistedRequest
        ) {
            try await streamImmediately(
                bookURL: bookURL,
                bookID: bookID,
                engine: engine,
                voice: voice,
                language: language,
                clearCache: clearCache,
                forceReprocess: forceReprocess,
                maxPerformance: maxPerformance,
                autoPlay: autoPlay,
                priorityChapterIndices: priorityChapterIndices,
                requestedChapterIndices: requestedChapterIndices,
                drivesPlayer: drivesPlayer,
                player: player,
                onStreamingStarted: onStreamingStarted,
                onChapterAvailable: onChapterAvailable
            )
        }
    }

    /// Update playback chrome at the Listen boundary, before local-cache and
    /// network scheduling can defer actual conversion work.
    @MainActor
    static func beginPlaybackPreparationIfNeeded(
        drivesPlayer: Bool,
        player: AudioPlayer
    ) {
        guard drivesPlayer else { return }
        player.beginPlaybackPreparation()
    }

    /// Recreates the closures for conversion work which iOS interrupted. The
    /// scheduler restores FIFO order; resumption stays background-only so an
    /// app relaunch never begins audible playback without a user action.
    @MainActor
    static func resumePendingWork(
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer
    ) {
        guard settings.useEmbeddedRuntime else { return }
        let requests = LocalAudioConversionScheduler.shared.takePendingResumeRequests()
        for request in requests {
            guard let book = library.books.first(where: { $0.id == request.bookID }),
                  !book.fileType.requiresServerConversion,
                  let url = try? library.openBookFile(id: request.bookID) else {
                continue
            }
            Task { @MainActor in
                _ = try? await stream(
                    bookURL: url,
                    bookID: request.bookID,
                    engine: request.engine,
                    voice: request.voice,
                    language: request.language,
                    clearCache: request.clearCache,
                    forceReprocess: request.forceReprocess,
                    maxPerformance: request.maxPerformance,
                    autoPlay: false,
                    requiresWiFi: !settings.allowCellularAudioConversion,
                    priorityChapterIndices: request.priorityChapterIndices,
                    requestedChapterIndices: request.requestedChapterIndices,
                    drivesPlayer: false,
                    player: player,
                    resumeRequest: request
                )
            }
        }
    }

    @MainActor
    private static func streamImmediately(
        bookURL: URL,
        bookID: String,
        engine: String,
        voice: String,
        language: String?,
        clearCache: Bool,
        forceReprocess: Bool,
        maxPerformance: Bool,
        autoPlay: Bool,
        priorityChapterIndices: [Int],
        requestedChapterIndices: [Int]?,
        drivesPlayer: Bool,
        player: AudioPlayer,
        onStreamingStarted: @MainActor @escaping () -> Void,
        onChapterAvailable: @MainActor @escaping (JobSnapshot.Chapter) -> Void
    ) async throws -> JobSnapshot {
        let request = StreamRequest(
            bookID: bookID,
            engine: engine.lowercased(),
            voice: voice.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language,
            clearCache: clearCache,
            forceReprocess: forceReprocess,
            maxPerformance: maxPerformance,
            priorityChapterIndices: Array(Set(priorityChapterIndices)).sorted(),
            requestedChapterIndices: requestedChapterIndices.map { Array(Set($0)).sorted() }
        )
        if let active = activeStream {
            if active.request == request,
               active.player === player,
               let task = active.task {
                // A repeated Listen tap for the same book joins the live
                // stream instead of creating a second segment producer.
                onStreamingStarted()
                return try await task.value
            }
            cancel(active)
        }

        let lease = StreamLease(request: request, drivesPlayer: drivesPlayer, player: player)
        activeStream = lease
        let task = Task { @MainActor in
            try await runStream(
                bookURL: bookURL,
                bookID: bookID,
                engine: engine,
                voice: voice,
                language: language,
                clearCache: clearCache,
                forceReprocess: forceReprocess,
                maxPerformance: maxPerformance,
                autoPlay: autoPlay,
                priorityChapterIndices: priorityChapterIndices,
                requestedChapterIndices: requestedChapterIndices,
                drivesPlayer: drivesPlayer,
                player: player,
                lease: lease,
                onStreamingStarted: onStreamingStarted,
                onChapterAvailable: onChapterAvailable
            )
        }
        lease.task = task
        return try await task.value
    }

    /// Cancels only a stream that owns audible playback. Background download
    /// work is intentionally left alone when the reader changes books.
    @MainActor
    static func cancelActiveStream() {
        guard let active = activeStream, active.ownsPlayback else { return }
        cancel(active)
    }

    @MainActor
    private static func cancel(_ lease: StreamLease) {
        if activeStream?.id == lease.id {
            activeStream = nil
        }
        PythonBridge.shared.cancelActiveSynthesis()
        lease.task?.cancel()
        if lease.ownsPlayback {
            lease.player?.stop()
            lease.player?.clearConversionState()
        }
    }

    @MainActor
    private static func isActive(_ lease: StreamLease) -> Bool {
        activeStream?.id == lease.id && lease.task?.isCancelled != true
    }

    @MainActor
    private static func retire(_ lease: StreamLease) {
        guard activeStream?.id == lease.id else { return }
        activeStream = nil
    }

    @MainActor
    private static func playbackPlayer(for lease: StreamLease, fallback: AudioPlayer) -> AudioPlayer {
        lease.playbackAttachment?.player ?? fallback
    }

    /// A download may be in the middle of a chapter when the user presses
    /// Listen. The active chapter is allowed to finish, then this begins a
    /// normal segment-streaming player session before the prioritised reader
    /// chapter starts. This preserves the download and avoids replaying the
    /// already-running chapter unexpectedly.
    @MainActor
    private static func beginAttachedPlaybackIfNeeded(
        lease: StreamLease,
        initial: JobSnapshot,
        payload: EbookFulltext
    ) {
        guard let attachment = lease.playbackAttachment, !attachment.hasBegun else { return }
        let player = attachment.player
        let requestedIndex = attachment.priorityChapterIndices.first
        let startingAt = initial.chapterProgress?.firstIndex {
            $0.index == requestedIndex
        } ?? 0
        attachment.hasBegun = true
        lease.player = player
        player.stop()
        player.clearConversionState()
        player.isConverting = true
        player.updateReaderChapterTitles(payload.chapters)
        player.play(snapshot: initial, startingAt: startingAt)
        if attachment.autoPlay { player.resume() }
        attachment.onStreamingStarted()
    }

    @MainActor
    private static func runStream(
        bookURL: URL,
        bookID: String,
        engine: String,
        voice: String,
        language: String?,
        clearCache: Bool,
        forceReprocess: Bool,
        maxPerformance: Bool,
        autoPlay: Bool,
        priorityChapterIndices: [Int],
        requestedChapterIndices: [Int]?,
        drivesPlayer: Bool,
        player: AudioPlayer,
        lease: StreamLease,
        onStreamingStarted: @MainActor @escaping () -> Void,
        onChapterAvailable: @MainActor @escaping (JobSnapshot.Chapter) -> Void
    ) async throws -> JobSnapshot {
        defer { retire(lease) }
        try Task.checkCancellation()

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
            guard isActive(lease) else { throw CancellationError() }
            if lease.ownsPlayback {
                player.stop()
                player.clearConversionState()
                player.isConverting = false
                player.play(snapshot: converted)
                if autoPlay { player.resume() }
                onStreamingStarted()
            }
            converted.chapterProgress?.forEach(onChapterAvailable)
            return converted
        }

        // A completed local book must remain playable even when a later app
        // launch cannot bootstrap Python or reach Edge. Reuse only complete,
        // non-empty local MP3s; partial jobs still enter the normal recovery
        // path so their remaining chapters cannot be misrepresented as done.
        if !clearCache,
           !forceReprocess,
           let cached = try? await LocalAudioArtifactStore.shared.completedSnapshot(
                bookID: bookID,
                engine: engine,
                voice: voice,
                language: language
           ) {
            guard isActive(lease) else { throw CancellationError() }
            if lease.ownsPlayback {
                player.stop()
                player.clearConversionState()
                let startingAt = cached.playableChapters.firstIndex {
                    priorityChapterIndices.contains($0.index)
                } ?? 0
                player.play(snapshot: cached, startingAt: startingAt)
                if autoPlay { player.resume() }
                onStreamingStarted()
            }
            cached.chapterProgress?.forEach(onChapterAvailable)
            return cached
        }

        // The legacy snapshot exists only to promote audio generated before
        // LocalAudioArtifactStore became the durable source of truth.
        if !clearCache,
           !forceReprocess,
           let cached = completedReusableSnapshot(bookID: bookID) {
            let migrated = try await migrateReusableSnapshotToArtifactStore(cached, bookID: bookID)
            UserDefaults.standard.removeObject(forKey: snapshotKey(bookID: bookID))
            guard isActive(lease) else { throw CancellationError() }
            if lease.ownsPlayback {
                player.stop()
                player.clearConversionState()
                let startingAt = migrated.playableChapters.firstIndex {
                    priorityChapterIndices.contains($0.index)
                } ?? 0
                player.play(snapshot: migrated, startingAt: startingAt)
                if autoPlay { player.resume() }
                onStreamingStarted()
            }
            migrated.chapterProgress?.forEach(onChapterAvailable)
            return migrated
        }

        // Lifecycle warmup runs opportunistically when the scene activates;
        // Listen is the authoritative readiness gate so it cannot race that
        // background task on a cold launch.
        try await PythonBridge.shared.preflightRuntime()
        guard isActive(lease) else { throw CancellationError() }

        let directories = try conversionDirectories(
            bookID: bookID,
            clearCache: clearCache,
            forceReprocess: forceReprocess
        )
        let payload = try await preparedFulltext(
            bookURL: bookURL,
            bookID: bookID,
            cacheDirectory: directories.cache,
            clearCache: clearCache
        )
        guard isActive(lease) else { throw CancellationError() }

        LocalFulltextCache.save(payload, bookId: bookID)
        if drivesPlayer {
            player.updateReaderChapterTitles(payload.chapters)
        }
        let narratable = payload.chapters.filter {
            let speech = ($0.speechText ?? $0.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !speech.isEmpty
        }
        guard !narratable.isEmpty else {
            throw PythonBridgeError.convertFailed("The book has no narratable chapters.")
        }
        let conversionOrder = prioritizedChapters(
            narratable,
            priorityChapterIndices: priorityChapterIndices
        )
        let chaptersToGenerate: [EbookFulltext.Chapter]
        if let requestedChapterIndices {
            let requested = Set(requestedChapterIndices)
            chaptersToGenerate = conversionOrder.filter {
                requested.contains($0.zeroBasedEpubIndex)
            }
            guard !chaptersToGenerate.isEmpty else {
                throw PythonBridgeError.convertFailed("The requested chapter is unavailable for conversion.")
            }
        } else {
            chaptersToGenerate = conversionOrder
        }

        let audioArtifacts = LocalAudioArtifactStore.shared
        try await audioArtifacts.prepare(
            bookID: bookID,
            bookTitle: payload.bookTitle ?? bookID,
            author: payload.bookAuthor,
            chapters: narratable.map {
                .init(index: $0.zeroBasedEpubIndex, title: $0.displayTitle)
            }
        )
        if clearCache || forceReprocess {
            try await audioArtifacts.clearTemporaryAudio(bookID: bookID)
        }
        LocalAudioConversionScheduler.shared.markInitialCacheActionHandled(bookID: bookID)

        let requestedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVoice = requestedVoice.isEmpty || requestedVoice.lowercased() == "auto"
            ? VoiceSelector.edgeVoice(
                for: narratable[0].speechText ?? narratable[0].text,
                declaredLanguage: language
            )
            : requestedVoice
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
                    index: chapter.zeroBasedEpubIndex,
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
        if drivesPlayer {
            // A replacement stream must start from a clean AVQueuePlayer. The
            // active-stream fence handles late callbacks; stopping here removes
            // already-enqueued items from a prior completed or cancelled job.
            player.stop()
            player.clearConversionState()
            player.isConverting = true
            player.play(snapshot: initial)
            if autoPlay { player.resume() }
            onStreamingStarted()
        }

        var completed: [JobSnapshot.Chapter] = []
        var errors: [String] = []
        var remainingChapters = Dictionary(
            uniqueKeysWithValues: chaptersToGenerate.map { ($0.zeroBasedEpubIndex, $0) }
        )
        while !remainingChapters.isEmpty {
            guard let nextIndex = LocalAudioConversionScheduler.shared.nextChapterIndex(
                bookID: bookID,
                available: Set(remainingChapters.keys),
                defaultOrder: chaptersToGenerate.map(\.zeroBasedEpubIndex)
            ), let chapter = remainingChapters.removeValue(forKey: nextIndex) else {
                break
            }
            beginAttachedPlaybackIfNeeded(lease: lease, initial: initial, payload: payload)
            let activePlayer = playbackPlayer(for: lease, fallback: player)
            if LocalAudioConversionScheduler.shared.state(for: bookID) == .waitingForWiFi {
                try? await audioArtifacts.markWaitingForWiFi(
                    bookID: bookID,
                    chapterIndex: chapter.zeroBasedEpubIndex
                )
            }
            LocalAudioConversionScheduler.shared.refreshDeviceResourceConstraint()
            await LocalAudioConversionScheduler.shared.waitForResourceStability(bookID: bookID)
            await LocalAudioConversionScheduler.shared.waitForNetworkPermission(bookID: bookID)
            try Task.checkCancellation()
            guard isActive(lease) else { throw CancellationError() }
            let outputURL = try await audioArtifacts.canonicalURL(
                bookID: bookID,
                chapterIndex: chapter.zeroBasedEpubIndex
            )

            do {
                if let cachedAudio = await reusableAudio(at: outputURL) {
                    try await audioArtifacts.markAvailable(
                        bookID: bookID,
                        chapterIndex: chapter.zeroBasedEpubIndex
                    )
                    if lease.ownsPlayback {
                        // Feed a cached chapter through the existing segment
                        // queue. This preserves chapter order when a cached file
                        // is followed by newly streaming chapters (or vice versa).
                        guard await activePlayer.waitForSegmentCapacity() else {
                            throw CancellationError()
                        }
                        guard isActive(lease) else {
                            throw CancellationError()
                        }
                        activePlayer.enqueueSegment(
                            data: cachedAudio,
                            chapterIndex: chapter.zeroBasedEpubIndex,
                            segmentIndex: 0
                        )
                    }
                } else {
                    try await audioArtifacts.markGenerating(
                        bookID: bookID,
                        chapterIndex: chapter.zeroBasedEpubIndex
                    )
                    let emission = SegmentEmission()
                    let onSegment: @MainActor @Sendable (Data, Int, Int) async -> Bool = {
                        data, chapterIndex, segmentIndex in
                        guard isActive(lease) else { return false }
                        // A callback means synthesis has already produced
                        // audible bytes, even for background downloads where
                        // the mini player intentionally stays untouched.
                        // Retrying that partial request would not be a clean
                        // retry, so leave it for an explicit user retry.
                        emission.didEmit = true
                        guard lease.ownsPlayback else { return true }
                        guard await activePlayer.waitForSegmentCapacity() else { return false }
                        guard isActive(lease) else { return false }
                        activePlayer.enqueueSegment(
                            data: data,
                            chapterIndex: chapterIndex,
                            segmentIndex: segmentIndex
                        )
                        return true
                    }
                    var output: URL?
                    for attempt in 0..<Self.maximumAutomaticChapterAttempts {
                        do {
                            if streamingMode(maxPerformance: maxPerformance) == .orderedParallel {
                                // Explicit high-throughput mode uses the bounded
                                // Swift WebSocket pool. Python still owns canonical
                                // text preparation and chunking; PythonBridge holds a
                                // reorder barrier so AVQueuePlayer only sees segments
                                // in source order, beginning with chunk zero.
                                output = try await PythonBridge.shared.convertChapterParallel(
                                    text: chapter.speechText ?? chapter.text,
                                    voice: resolvedVoice,
                                    outputDir: outputURL.deletingLastPathComponent(),
                                    outputURL: outputURL,
                                    chapterIndex: chapter.zeroBasedEpubIndex,
                                    onSegment: onSegment
                                )
                            } else {
                                output = try await PythonBridge.shared.convertChapterStreaming(
                                    text: chapter.speechText ?? chapter.text,
                                    voice: resolvedVoice,
                                    outputURL: outputURL,
                                    chapterIndex: chapter.zeroBasedEpubIndex,
                                    onSegment: onSegment
                                )
                            }
                            break
                        } catch {
                            // Retrying after a segment reached AVQueuePlayer would
                            // duplicate audible text. Retry only one clean
                            // failure, then persist the failure for manual retry.
                            guard attempt < Self.maximumAutomaticChapterAttempts - 1,
                                  !emission.didEmit else {
                                throw error
                            }
                            try? FileManager.default.removeItem(at: outputURL)
                            try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                        }
                    }
                    guard output == outputURL,
                          isReusableAudio(at: outputURL) else {
                        throw PythonBridgeError.convertFailed(
                            "streaming synthesis did not produce a reusable chapter file"
                        )
                    }
                    try await audioArtifacts.markAvailable(
                        bookID: bookID,
                        chapterIndex: chapter.zeroBasedEpubIndex
                    )
                    guard isActive(lease) else { throw CancellationError() }
                }

                completed.append(completedChapter(chapter, outputURL: outputURL))
                if let completedChapter = completed.last {
                    onChapterAvailable(completedChapter)
                }
                _ = publishLiveSnapshot(
                    bookID: bookID,
                    title: payload.bookTitle,
                    author: payload.bookAuthor,
                    engine: engine,
                    voice: resolvedVoice,
                    language: language,
                    narratable: narratable,
                    completed: completed,
                    errors: errors,
                    player: activePlayer,
                    updatesPlayer: lease.ownsPlayback
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                if StoragePressureError.isInsufficientSpace(error) {
                    try? await audioArtifacts.markFailed(
                        bookID: bookID,
                        chapterIndex: chapter.zeroBasedEpubIndex,
                        errorDescription: StoragePressureError.insufficientSpace.localizedDescription
                    )
                    throw StoragePressureError.insufficientSpace
                }
                try? await audioArtifacts.markFailed(
                    bookID: bookID,
                    chapterIndex: chapter.zeroBasedEpubIndex,
                    errorDescription: error.localizedDescription
                )
                errors.append("Chapter \(chapter.index): \(error.localizedDescription)")
                guard isActive(lease) else { throw CancellationError() }
                _ = publishLiveSnapshot(
                    bookID: bookID,
                    title: payload.bookTitle,
                    author: payload.bookAuthor,
                    engine: engine,
                    voice: resolvedVoice,
                    language: language,
                    narratable: narratable,
                    completed: completed,
                    errors: errors,
                    player: activePlayer,
                    updatesPlayer: lease.ownsPlayback
                )
            }
        }

        guard !completed.isEmpty else {
            if lease.ownsPlayback { playbackPlayer(for: lease, fallback: player).isConverting = false }
            throw PythonBridgeError.convertFailed(errors.joined(separator: "\n"))
        }
        let finalState = errors.isEmpty && completed.count == narratable.count ? "finished" : "partial"
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
            state: errors.isEmpty ? finalState : "failed"
        )
        guard isActive(lease) else { throw CancellationError() }
        if final.state == "finished" {
            _ = try await audioArtifacts.promoteAvailable(bookID: bookID)
        }
        if lease.ownsPlayback {
            playbackPlayer(for: lease, fallback: player).finishEmbeddedStreaming(snapshot: final)
        }
        return final
    }

    private static func preparedFulltext(
        bookURL: URL,
        bookID: String,
        cacheDirectory: URL,
        clearCache: Bool
    ) async throws -> EbookFulltext {
        if !clearCache {
            let persistent = await Task.detached(priority: .userInitiated) {
                cachedFulltext(at: cacheDirectory)
            }.value
            if let persistent, hasCanonicalSpeechText(persistent) {
                return persistent
            }

            let evictable = await Task.detached(priority: .userInitiated) {
                LocalFulltextCache.read(bookId: bookID)
            }.value
            if let evictable, hasCanonicalSpeechText(evictable) {
                saveFulltext(evictable, to: cacheDirectory)
                return evictable
            }
        }

        let parsed = try await PythonBridge.shared.parseEpub(at: bookURL, bookId: bookID)
        guard hasCanonicalSpeechText(parsed) else {
            throw PythonBridgeError.convertFailed(
                "The embedded parser did not provide canonical prepared speech text."
            )
        }
        saveFulltext(parsed, to: cacheDirectory)
        return parsed
    }

    static func hasCanonicalSpeechText(_ payload: EbookFulltext) -> Bool {
        let narratable = payload.chapters.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !narratable.isEmpty && narratable.allSatisfy {
            !($0.speechText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func isReusableCompletedSnapshot(_ snapshot: JobSnapshot) -> Bool {
        guard snapshot.state == "finished" else { return false }
        let chapters = snapshot.playableChapters
        guard !chapters.isEmpty,
              snapshot.chaptersCompleted == snapshot.chaptersTotal,
              chapters.count == snapshot.chaptersTotal else {
            return false
        }
        return chapters.allSatisfy { chapter in
            guard let path = chapter.downloadUrl,
                  let url = URL(string: path),
                  url.isFileURL else {
                return false
            }
            return isReusableAudio(at: url)
        }
    }

    private static func completedReusableSnapshot(bookID: String) -> JobSnapshot? {
        guard let snapshot = loadSnapshot(bookID: bookID),
              isReusableCompletedSnapshot(snapshot) else {
            return nil
        }
        return snapshot
    }

    /// Moves valid MP3s written by the pre-manifest embedded pipeline into
    /// the canonical artifact location. The operation is a move on the same
    /// app volume, so migration removes the duplicate legacy source instead
    /// of charging the user for a second copy of their audiobook.
    private static func migrateReusableSnapshotToArtifactStore(
        _ snapshot: JobSnapshot,
        bookID: String
    ) async throws -> JobSnapshot {
        guard let chapterProgress = snapshot.chapterProgress, !chapterProgress.isEmpty else {
            return snapshot
        }
        let artifacts = LocalAudioArtifactStore.shared
        try await artifacts.prepare(
            bookID: bookID,
            bookTitle: snapshot.bookTitle ?? bookID,
            author: snapshot.bookAuthor,
            chapters: chapterProgress.map {
                .init(index: $0.index, title: $0.displayTitle)
            }
        )
        var migratedChapters: [JobSnapshot.Chapter] = []
        for chapter in chapterProgress {
            guard let rawURL = chapter.downloadUrl,
                  let sourceURL = URL(string: rawURL),
                  sourceURL.isFileURL,
                  isReusableAudio(at: sourceURL) else {
                migratedChapters.append(chapter)
                continue
            }
            let targetURL = try await artifacts.canonicalURL(bookID: bookID, chapterIndex: chapter.index)
            try moveReusableAudio(from: sourceURL, to: targetURL)
            try await artifacts.markAvailable(bookID: bookID, chapterIndex: chapter.index)
            migratedChapters.append(JobSnapshot.Chapter(
                index: chapter.index,
                name: chapter.name,
                status: chapter.status,
                downloadUrl: targetURL.absoluteString,
                chars: chapter.chars,
                charsProcessed: chapter.charsProcessed,
                progressRatio: chapter.progressRatio,
                durationSeconds: chapter.durationSeconds,
                startedAt: chapter.startedAt,
                completedAt: chapter.completedAt
            ))
        }
        var migrated = snapshot
        migrated.chapterProgress = migratedChapters
        return migrated
    }

    /// Keeps a single durable audio file when legacy or batch conversion
    /// output is adopted by LocalAudioArtifactStore. Same-volume moves are
    /// atomic; a copy is only the fallback for a provider that wrote outside
    /// app storage, and its source is removed immediately afterwards.
    private static func moveReusableAudio(from sourceURL: URL, to targetURL: URL) throws {
        guard sourceURL.standardizedFileURL != targetURL.standardizedFileURL else { return }
        if isReusableAudio(at: targetURL) {
            try? FileManager.default.removeItem(at: sourceURL)
            return
        }
        try? FileManager.default.removeItem(at: targetURL)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: targetURL)
        } catch {
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }
    }

    private static func cachedFulltext(at cacheDirectory: URL) -> EbookFulltext? {
        guard let data = try? Data(contentsOf: fulltextCacheURL(in: cacheDirectory)) else {
            return nil
        }
        return try? JSONDecoder().decode(EbookFulltext.self, from: data)
    }

    private static func saveFulltext(_ payload: EbookFulltext, to cacheDirectory: URL) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fulltextCacheURL(in: cacheDirectory), options: [.atomic])
    }

    private static func fulltextCacheURL(in cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent("prepared-fulltext.json")
    }

    private static func chapterOutputURL(
        for chapter: EbookFulltext.Chapter,
        outputDirectory: URL
    ) -> URL {
        outputDirectory.appendingPathComponent("chapter-\(chapter.index).mp3")
    }

    private static func audioOutputDirectory(in root: URL, voice: String) -> URL {
        let normalized = voice.lowercased().unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let safeVoice = normalized
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return root.appendingPathComponent(
            "edge-\(safeVoice.isEmpty ? "auto" : safeVoice)",
            isDirectory: true
        )
    }

    static func isReusableAudio(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= 1_024,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 3), header.count >= 3 else {
            return false
        }
        let bytes = [UInt8](header)
        // Edge emits either raw MPEG frames or an ID3 header. Reject a
        // zero-byte / partial / HTML error response before it becomes a
        // reusable local audiobook chapter.
        return bytes.starts(with: [0x49, 0x44, 0x33])
            || (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)
    }

    private static func reusableAudio(at url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            guard isReusableAudio(at: url),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  !data.isEmpty else {
                return nil
            }
            return data
        }.value
    }

    private static func completedChapter(
        _ chapter: EbookFulltext.Chapter,
        outputURL: URL
    ) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: chapter.zeroBasedEpubIndex,
            name: chapter.displayTitle,
            status: "completed",
            downloadUrl: outputURL.absoluteString,
            chars: chapter.charCount,
            charsProcessed: chapter.charCount,
            progressRatio: 1,
            durationSeconds: nil,
            startedAt: nil,
            completedAt: Date().timeIntervalSince1970
        )
    }

    @MainActor
    private static func publishLiveSnapshot(
        bookID: String,
        title: String?,
        author: String?,
        engine: String,
        voice: String,
        language: String?,
        narratable: [EbookFulltext.Chapter],
        completed: [JobSnapshot.Chapter],
        errors: [String],
        player: AudioPlayer,
        updatesPlayer: Bool
    ) -> JobSnapshot {
        let live = liveSnapshot(
            bookID: bookID,
            title: title,
            author: author,
            engine: engine,
            voice: voice,
            language: language,
            narratable: narratable,
            completed: completed,
            errors: errors
        )
        if updatesPlayer {
            player.updateSnapshot(live)
        }
        return live
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
        let directories = try conversionDirectories(
            bookID: bookID,
            clearCache: clearCache,
            forceReprocess: forceReprocess
        )
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
        let artifactStore = LocalAudioArtifactStore.shared
        let chapterCount = max(result.manifest.count, result.outputs.count)
        let chapterSeeds = (0..<chapterCount).map { index in
            LocalAudioArtifactStore.ChapterSeed(
                index: index,
                title: result.manifest[safe: index]?.name ?? "Chapter \(index + 1)"
            )
        }
        try await artifactStore.prepare(
            bookID: bookID,
            bookTitle: result.bookTitle,
            author: result.bookAuthor,
            chapters: chapterSeeds
        )
        if clearCache || forceReprocess {
            try await artifactStore.clearTemporaryAudio(bookID: bookID)
        }
        await LocalAudioConversionScheduler.shared.markInitialCacheActionHandled(bookID: bookID)

        let manifestsByFilename = Dictionary(
            result.manifest.enumerated().compactMap { offset, manifest -> (String, (Int, PythonBridge.ChapterEntry))? in
                guard let outputPath = manifest.outputPath else { return nil }
                return (URL(fileURLWithPath: outputPath).lastPathComponent, (offset, manifest))
            },
            uniquingKeysWith: { first, _ in first }
        )
        var playable: [JobSnapshot.Chapter] = []
        var errors = result.errors
        for (offset, sourceURL) in result.outputs.enumerated() {
            let matched = manifestsByFilename[sourceURL.lastPathComponent]
                ?? result.manifest[safe: offset].map { (offset, $0) }
            let chapterIndex = matched?.0 ?? offset
            guard isReusableAudio(at: sourceURL) else {
                errors.append("Generated audio for chapter \(chapterIndex + 1) is invalid.")
                try? await artifactStore.markFailed(
                    bookID: bookID,
                    chapterIndex: chapterIndex,
                    errorDescription: "Generated audio is invalid."
                )
                continue
            }
            do {
                let targetURL = try await artifactStore.canonicalURL(
                    bookID: bookID,
                    chapterIndex: chapterIndex
                )
                try moveReusableAudio(from: sourceURL, to: targetURL)
                try await artifactStore.markAvailable(bookID: bookID, chapterIndex: chapterIndex)
                let manifest = matched?.1
                playable.append(JobSnapshot.Chapter(
                    index: chapterIndex,
                    name: manifest?.name,
                    status: "completed",
                    downloadUrl: targetURL.absoluteString,
                    chars: manifest?.charCount,
                    charsProcessed: manifest?.charCount,
                    progressRatio: 1,
                    durationSeconds: nil,
                    startedAt: nil,
                    completedAt: nil
                ))
            } catch {
                errors.append(error.localizedDescription)
                try? await artifactStore.markFailed(
                    bookID: bookID,
                    chapterIndex: chapterIndex,
                    errorDescription: error.localizedDescription
                )
            }
        }
        guard !playable.isEmpty else {
            let details = result.errors.joined(separator: "\n")
            throw PythonBridgeError.convertFailed(
                details.isEmpty ? "Embedded conversion produced no audio." : details
            )
        }

        let snapshot = JobSnapshot(
            jobId: jobID(for: bookID),
            state: errors.isEmpty ? "finished" : "running",
            bookTitle: result.bookTitle,
            bookAuthor: result.bookAuthor,
            coverUrl: nil,
            coverMimeType: nil,
            engine: engine,
            voice: voice,
            language: language,
            progressPercent: Double(playable.count) / Double(max(1, chapterCount)) * 100,
            chaptersTotal: chapterCount,
            chaptersCompleted: playable.count,
            chapterProgress: playable,
            outputs: nil,
            logUrl: nil,
            error: errors.isEmpty ? nil : errors.joined(separator: "\n"),
            lastActivityAt: Date().timeIntervalSince1970
        )
        if snapshot.state == "finished" {
            _ = try await artifactStore.promoteAvailable(bookID: bookID)
        }
        return snapshot
    }

    static func jobID(for bookID: String) -> String {
        "embedded-\(bookID)"
    }

    static func localSchedulingKey(
        drivesPlayer: Bool,
        requestedChapterIndices: [Int]?
    ) -> String {
        guard !drivesPlayer else { return "playback" }
        guard let requestedChapterIndices, !requestedChapterIndices.isEmpty else {
            return "download-all"
        }
        let indices = Array(Set(requestedChapterIndices)).sorted()
        return "download-chapters-\(indices.map(String.init).joined(separator: "-"))"
    }

    static func embeddedBookID(from jobID: String) -> String? {
        let prefix = "embedded-"
        guard jobID.hasPrefix(prefix) else { return nil }
        let bookID = String(jobID.dropFirst(prefix.count))
        return bookID.isEmpty ? nil : bookID
    }

    static func localCacheAction(
        clearCache: Bool,
        forceReprocess: Bool
    ) -> LocalCacheAction {
        if clearCache { return .clearBook }
        if forceReprocess { return .regenerateOutputs }
        return .reuse
    }

    static func streamingMode(maxPerformance: Bool) -> StreamingMode {
        maxPerformance ? .orderedParallel : .lowestLatencySerial
    }

    static func prioritizedChapterIndices(source: [Int], priorities: [Int]) -> [Int] {
        let sourceSet = Set(source)
        var seenPriorities: Set<Int> = []
        let priorityOrder = priorities.filter {
            sourceSet.contains($0) && seenPriorities.insert($0).inserted
        }
        let prioritized = Set(priorityOrder)
        return priorityOrder + source.filter { !prioritized.contains($0) }
    }

    private static func prioritizedChapters(
        _ chapters: [EbookFulltext.Chapter],
        priorityChapterIndices: [Int]
    ) -> [EbookFulltext.Chapter] {
        let order = prioritizedChapterIndices(
            source: chapters.map(\.zeroBasedEpubIndex),
            priorities: priorityChapterIndices
        )
        let chaptersByIndex = Dictionary(uniqueKeysWithValues: chapters.map { ($0.zeroBasedEpubIndex, $0) })
        return order.compactMap { chaptersByIndex[$0] }
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
            saveLegacySnapshot(reconciled, bookID: bookID)
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

    private static func saveLegacySnapshot(_ snapshot: JobSnapshot, bookID: String) {
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

    private static func conversionDirectories(
        bookID: String,
        clearCache: Bool = false,
        forceReprocess: Bool = false
    ) throws -> (output: URL, cache: URL) {
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

        switch localCacheAction(
            clearCache: clearCache,
            forceReprocess: forceReprocess
        ) {
        case .clearBook:
            // `clearCache` has the same observable meaning as the CLI flag:
            // discard both parsed text and final MP3s for this book only.
            if FileManager.default.fileExists(atPath: bookRoot.path) {
                try FileManager.default.removeItem(at: bookRoot)
            }
            LocalFulltextCache.evict(bookId: bookID)
            UserDefaults.standard.removeObject(forKey: snapshotKey(bookID: bookID))
        case .regenerateOutputs:
            // Keep canonical parsed text but force fresh Edge output. A saved
            // snapshot would otherwise keep URLs pointing at files we just
            // removed, so invalidate it with the generated audio.
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            UserDefaults.standard.removeObject(forKey: snapshotKey(bookID: bookID))
        case .reuse:
            break
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        protectConversionDirectory(bookRoot)
        protectConversionDirectory(output)
        protectConversionDirectory(cache)
        return (output, cache)
    }

    /// Converted books are recreatable cache data. Keep them out of backups
    /// and available after the first device unlock, so background playback
    /// cannot lose access to the next queued MP3 when the screen locks.
    private static func protectConversionDirectory(_ directory: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedDirectory = directory
        try? protectedDirectory.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        #endif
    }

    private static func protectCachedAudio(at url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = url
        try? protectedURL.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
