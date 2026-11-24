#if os(macOS)
import AppKit

@MainActor
final class MacReaderPlaybackSession {
    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let conversionExecutor: RustConversionCoordinator.StreamingExecutor
    private let makePlaybackControl: @MainActor () throws -> ConverterPlaybackControl
    private(set) var localPlaybackBookID: String?
    private(set) var isStartingLocalPlayback = false
    private(set) var localPlaybackGeneration: String?
    private var requestedPDFPosition: (chapter: Int, offset: Int)?
    private var requestedVoice: TtsSelection?
    private(set) var startingVoicePosition: ReaderVoiceChange?
    private var localPlaybackChapters: [JobSnapshot.Chapter] = []
    private(set) var localPlaybackControl: ConverterPlaybackControl?

    init(settings: AppSettings, library: LibraryStore, player: AudioPlayer,
         playerPresentation: PlayerPresentation,
         conversionExecutor: @escaping RustConversionCoordinator.StreamingExecutor,
         makePlaybackControl: (@MainActor () throws -> ConverterPlaybackControl)? = nil) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playerPresentation = playerPresentation
        self.conversionExecutor = conversionExecutor
        self.makePlaybackControl = makePlaybackControl ?? { try RustConversionCoordinator.makePlaybackControl() }
    }

    func voicePickerRequest(bookID: String, owner: AnyObject,
                            isCurrent: @escaping @MainActor () -> Bool) -> ReaderVoicePickerRequest {
        ReaderVoicePickerRequest(settings: settings, library: library, player: player, currentContext: { [weak self] in
            guard let self, isCurrent(), let book = library.books.first(where: { $0.id == bookID }) else { return nil }
            guard localPlaybackBookID == bookID else { return .init(book: book) }
            return .init(book: book, jobID: localPlaybackGeneration, requestedVoice: requestedVoice,
                startingPosition: startingVoicePosition, pdfPosition: requestedPDFPosition)
        }) { [weak self, weak owner] target, options in
            guard let self, let owner else { return }
            start(owner: owner, optionsOverride: options, chapterOverride: target.chapter,
                pageRatioOverride: .some(target.pageRatio), voiceChange: target)
        }
    }

    // The double optional distinguishes "use the current page" from an explicit nil page.
    func start(owner: AnyObject, optionsOverride: ConversionOptions? = nil,
               chapterOverride: Int? = nil, pageRatioOverride: Double?? = nil,
               pdfAnchor: PDFReadingAudioMap.Anchor? = nil, voiceChange: ReaderVoiceChange? = nil) {
        playerPresentation.dismissFullPlayer()
        let defaults = UserDefaults.standard
        guard let bookID = defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
              let book = library.books.first(where: { $0.id == bookID }),
              // Comics are read visually; there is no text to narrate (matches iOS reader listening).
              book.fileType.supportsAudioConversion else { return }
        // The book's language is resolved first (analysis off the main thread, cached per book), unless
        // the listener made an explicit per-job selection.
        let chapterIndex = pdfAnchor?.chapterIndex ?? chapterOverride ?? ReaderPlaybackPriorityChapter.index(bookID: book.id)
        if optionsOverride == nil {
            // The Play intent (chapter and page) is captured now, not after the asynchronous resolution.
            let capturedRatio = pageRatioOverride ?? (defaults.object(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey) as? Double)
            // The request is visibly in progress right away (buttons, duplicate Play) while Rust resolves.
            localPlaybackBookID = book.id
            isStartingLocalPlayback = true
            resolveLanguageModelThenStart(book: book, owner: owner, chapterOverride: chapterIndex,
                pageRatioOverride: .some(capturedRatio), pdfAnchor: pdfAnchor, voiceChange: voiceChange)
            return
        }
        let chapterStart = Int32(exactly: chapterIndex) ?? 0
        let pageRatio = pageRatioOverride ?? (defaults.object(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey) as? Double)
        cancel(stopPlayer: false)
        let jobID = UUID().uuidString
        localPlaybackGeneration = jobID
        localPlaybackBookID = bookID
        isStartingLocalPlayback = true
        let conversionOptions = optionsOverride ?? NarrationConversionOptions.current(for: settings.ttsPreferences)
        requestedPDFPosition = (voiceChange?.sourceScalarOffset ?? pdfAnchor?.sourceScalarOffset)
            .map { (Int(chapterStart), $0) }
        requestedVoice = conversionOptions.ttsPreferences?.primary
        startingVoicePosition = voiceChange ?? .init(chapter: Int(chapterStart), pageRatio: pageRatio,
            seek: nil, autoplay: true, sourceScalarOffset: pdfAnchor?.sourceScalarOffset)
        let previousJobID = player.snapshot?.jobId
        Task { [weak self, owner] in
            guard let self else { return }
            defer { withExtendedLifetime(owner) {} }
            defer {
                if localPlaybackGeneration == jobID {
                    localPlaybackGeneration = nil
                    localPlaybackBookID = nil
                    localPlaybackControl = nil
                    isStartingLocalPlayback = false
                    startingVoicePosition = nil
                    requestedVoice = nil
                    requestedPDFPosition = nil
                }
            }
            do {
                let url = try await library.openBookFileAsync(id: book.id)
                guard localPlaybackGeneration == jobID, localPlaybackBookID == book.id else { return }
                if voiceChange != nil {
                    guard defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) == book.id,
                          player.snapshot?.jobId == previousJobID else { return }
                }
                localPlaybackChapters.removeAll()
                let playbackControl = try makePlaybackControl()
                playbackControl.trackPlayback(player)
                playbackControl.updatePlaybackWindow(
                    currentChapter: Int(chapterStart),
                    chaptersAhead: 1
                )
                if let sourceOffset = voiceChange?.sourceScalarOffset ?? pdfAnchor?.sourceScalarOffset {
                    playbackControl.startFromPage(sourceScalarOffset: sourceOffset)
                } else if let pageRatio {
                    playbackControl.startFromPage(ratio: pageRatio)
                }
                localPlaybackControl = playbackControl
                let pending = JobSnapshot(
                    jobId: jobID,
                    state: "running",
                    bookTitle: book.resolvedTitle,
                    bookAuthor: book.author,
                    coverUrl: nil,
                    coverMimeType: nil,
                    engine: nil,
                    voice: nil,
                    language: nil,
                    progressPercent: 0,
                    chaptersTotal: nil,
                    chaptersCompleted: 0,
                    chapterProgress: [],
                    outputs: nil,
                    logUrl: nil,
                    error: nil,
                    lastActivityAt: Date().timeIntervalSince1970,
                    chapterIndexBase: 0
                )
                // The normal empty-snapshot handoff can preserve a live segment queue.
                // A different voice needs an entirely new queue.
                if voiceChange != nil { player.stop() }
                PlaybackBindingStore.setCurrentlyPlaying(bookID: bookID, chapterIndex: chapterIndex)
                player.playbackClock.audioOutput.bindReaderJob(pending.jobId, to: book.id)
                player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
                player.isConverting = true
                if let seek = voiceChange?.seek { player.restoreListeningSeek(seek, jobID: jobID) }
                else if voiceChange?.autoplay != false { player.resume() }
                if voiceChange?.seek != nil { startingVoicePosition = nil }
                let chunkDelivery = StreamingPlaybackChunkDelivery(player: player)
                isStartingLocalPlayback = false
                let result = try await conversionExecutor(
                    url, jobID, chapterStart, -1, playbackControl, conversionOptions,
                    { [weak self] event in
                        guard let self,
                              self.localPlaybackGeneration == jobID, event.jobId == jobID,
                              event.state == "running",
                              let snapshot = self.player.snapshot,
                              snapshot.jobId == jobID else { return }
                        self.player.updateSnapshot(event.updating(snapshot))
                    },
                    { [weak self] event in
                        guard let self, self.localPlaybackGeneration == jobID, event.jobId == jobID,
                              self.player.snapshot?.jobId == jobID else { return }
                        guard playbackControl.acceptsChunks(forChapter: event.chapterIndex) else { return }
                        self.startingVoicePosition = nil
                        let firstPlayableChapter = self.localPlaybackChapters.isEmpty
                        let chapter = event.playableChapter
                        if let existing = self.localPlaybackChapters.firstIndex(where: { $0.index == chapter.index }) {
                            self.localPlaybackChapters[existing] = chapter
                        } else {
                            self.localPlaybackChapters.append(chapter)
                        }
                        self.localPlaybackChapters.sort { $0.index < $1.index }
                        self.player.updateSnapshot(
                            event.snapshot(chapters: self.localPlaybackChapters, preserving: self.player.snapshot)
                        )
                        if firstPlayableChapter, voiceChange == nil {
                            self.playerPresentation.showFullPlayer()
                        }
                    },
                    { chapterIndex, chunkIndex, data in
                        return chunkDelivery.enqueue(
                            data,
                            chapterIndex: chapterIndex,
                            chunkIndex: chunkIndex,
                            isCurrent: { [weak self] in
                                guard let self else { return false }
                                return self.localPlaybackGeneration == jobID
                                    && self.player.snapshot?.jobId == jobID
                                    && playbackControl.acceptsChunks(forChapter: chapterIndex)
                            },
                            onAccepted: { [weak self] in
                                guard let self, self.localPlaybackGeneration == jobID else { return }
                                self.startingVoicePosition = nil
                            }
                        )
                    }
                )
                guard localPlaybackGeneration == jobID, player.snapshot?.jobId == jobID else { return }
                let snapshot = try result.snapshot()
                guard result.jobID == jobID, snapshot.jobId == jobID else {
                    throw EmbeddedConverterError.conversionFailed("Conversion returned a different listening job.")
                }
                library.recordConversion(jobId: result.jobID, for: book.id)
                self.player.finishStreaming(snapshot: snapshot)
                if voiceChange == nil { self.playerPresentation.showFullPlayer() }
            } catch {
                guard localPlaybackGeneration == jobID else { return }
                if voiceChange != nil,
                   defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) != bookID { return }
                localPlaybackControl?.cancel()
                if let current = player.snapshot, current.jobId == jobID {
                    player.finishStreaming(snapshot: JobSnapshot(
                        jobId: current.jobId,
                        state: "failed",
                        bookTitle: current.bookTitle,
                        bookAuthor: current.bookAuthor,
                        coverUrl: current.coverUrl,
                        coverMimeType: current.coverMimeType,
                        engine: current.engine,
                        voice: current.voice,
                        language: current.language,
                        progressPercent: current.progressPercent,
                        chaptersTotal: current.chaptersTotal,
                        chaptersCompleted: current.chaptersCompleted,
                        chapterProgress: current.chapterProgress,
                        outputs: current.outputs,
                        logUrl: current.logUrl,
                        error: error.localizedDescription,
                        lastActivityAt: Date().timeIntervalSince1970,
                    chapterIndexBase: 0
                    ))
                }
                if BookLanguageUncertain.decode(error) != nil {
                    let recovered = await BookLanguagePicker.recover(error, bookID: bookID, isCurrent: { [weak self] in
                        self?.localPlaybackGeneration == jobID
                            && defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) == bookID
                    })
                    if recovered {
                        self.start(owner: owner, optionsOverride: conversionOptions,
                                   chapterOverride: Int(chapterStart), pageRatioOverride: .some(pageRatio),
                                   pdfAnchor: pdfAnchor, voiceChange: voiceChange)
                    }
                    return
                }
                if TtsLanguageMismatch.decode(error) != nil {
                    let choice = await TtsRecoveryAlert.choose(for: error, isCurrent: { [weak self] in
                        self?.localPlaybackGeneration == jobID
                            && defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) == bookID
                    })
                    if let choice {
                        self.start(owner: owner,
                                   optionsOverride: conversionOptions.recovering(with: choice.candidate, language: choice.language),
                                   chapterOverride: voiceChange == nil ? nil : Int(chapterStart),
                                   pageRatioOverride: voiceChange == nil ? nil : .some(pageRatio),
                                   pdfAnchor: pdfAnchor, voiceChange: voiceChange)
                    }
                    return
                }
                let alert = NSAlert()
                alert.messageText = L10n.string("bookDetail.listenStart")
                alert.informativeText = AppErrorReporter.message(error, context: "Reader listening")
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.runModal()
            }
        }
    }

    private var languageResolution: UUID?

    private func resolveLanguageModelThenStart(book: BookEntity, owner: AnyObject, chapterOverride: Int?,
                                               pageRatioOverride: Double??, pdfAnchor: PDFReadingAudioMap.Anchor?,
                                               voiceChange: ReaderVoiceChange?) {
        let token = UUID()
        languageResolution = token
        Task { [weak self, weak owner] in
            guard let self else { return }
            var handedOver = false
            // Not started (superseded, cancelled alert, deallocated owner): the pending state is dropped.
            defer {
                if !handedOver, languageResolution == token || languageResolution == nil, localPlaybackGeneration == nil {
                    localPlaybackBookID = nil
                    isStartingLocalPlayback = false
                }
            }
            let outcome = await LanguageModelPlayback.outcome(
                for: book, settings: settings, hasExplicitSelection: false, dependencies: .live(library: library))
            let stillWanted = { [weak self] in
                self?.languageResolution == token
                    && UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) == book.id
            }
            guard stillWanted(), let owner else { return }
            @MainActor func begin(_ options: ConversionOptions) {
                handedOver = true
                languageResolution = nil
                // Explicit options: the resolver is skipped on this second pass.
                start(owner: owner, optionsOverride: options, chapterOverride: chapterOverride,
                      pageRatioOverride: pageRatioOverride, pdfAnchor: pdfAnchor, voiceChange: voiceChange)
            }
            let saved = NarrationConversionOptions.current(for: settings.ttsPreferences)
            switch outcome {
            case .useSettings: begin(saved)
            case let .use(preferences): begin(NarrationConversionOptions.current(for: preferences))
            case let .missing(language):
                // Never downloads on its own: the recovery alert asks (download, system voice, Models).
                let error = LanguageModelPlayback.missingModelError(language: language)
                if let choice = await TtsRecoveryAlert.choose(for: error, isCurrent: stillWanted), stillWanted() {
                    begin(saved.recovering(with: choice.candidate, language: choice.language))
                }
            }
        }
    }

    /// Invalidate before cancellation so retiring callbacks cannot touch a replacement session.
    func cancel(ifReplacingBook incomingBookID: String? = nil, stopPlayer: Bool = true) {
        guard localPlaybackGeneration != nil,
              incomingBookID == nil || incomingBookID != localPlaybackBookID else { return }
        localPlaybackGeneration = nil
        localPlaybackBookID = nil
        isStartingLocalPlayback = false
        startingVoicePosition = nil
        requestedVoice = nil
        requestedPDFPosition = nil
        let retiring = localPlaybackControl
        localPlaybackControl = nil
        localPlaybackChapters.removeAll()
        retiring?.cancel()
        if stopPlayer {
            player.stop()
            player.clearConversionState()
        }
    }

}
#endif
