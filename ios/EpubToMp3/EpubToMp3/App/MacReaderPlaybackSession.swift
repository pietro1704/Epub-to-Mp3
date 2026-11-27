#if os(macOS)
import AppKit

@MainActor
final class MacReaderPlaybackSession {
    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let conversionExecutor: RustConversionCoordinator.StreamingExecutor
    private let makePlaybackControl: (@MainActor () throws -> ConverterPlaybackControl)?
    private let recovery = ReaderListeningRecovery()
    private weak var owner: AnyObject?
    /// Estimates owned by the open reader, for books without cached EPUB text such as PDFs.
    var readerChapterEstimates: (String) -> [Int: TimeInterval] = { _ in [:] }

    private lazy var listening = ReaderListeningSession(
        player: player, playerPresentation: playerPresentation, conversionExecutor: conversionExecutor,
        currentBookID: { [weak player] in player?.location.readingBookID },
        openBook: { [library] id in try await library.openBookFileAsync(id: id) },
        recordConversion: { [library] jobID, bookID in library.recordConversion(jobId: jobID, for: bookID) },
        reportFailure: { [weak self] error in self?.reportFailure(error) },
        chapterDelivery: .playbackWindow,
        bindPlayback: { [weak player] bookID, chapter in
            guard let player else { return }
            PlaybackBindingStore.setCurrentlyPlaying(bookID: bookID, chapterIndex: chapter, defaults: player.location.defaults)
        }, makePlaybackControl: makePlaybackControl
    )

    /// The request is visible as soon as Play is pressed: the book being resolved counts until the shared session takes over.
    private var resolvingBookID: String?
    var localPlaybackBookID: String? { listening.listeningBookID ?? resolvingBookID }
    var localPlaybackGeneration: String? { listening.listeningJobID }
    var startingVoicePosition: ReaderVoiceChange? { listening.startingVoicePosition }

    init(settings: AppSettings, library: LibraryStore, player: AudioPlayer,
         playerPresentation: PlayerPresentation,
         conversionExecutor: @escaping RustConversionCoordinator.StreamingExecutor,
         makePlaybackControl: (@MainActor () throws -> ConverterPlaybackControl)? = nil) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playerPresentation = playerPresentation
        self.conversionExecutor = conversionExecutor
        self.makePlaybackControl = makePlaybackControl
    }

    func observePlayback() { listening.observePlayback() }

    func voicePickerRequest(bookID: String, owner: AnyObject,
                            isCurrent: @escaping @MainActor () -> Bool) -> ReaderVoicePickerRequest {
        ReaderVoicePickerRequest(settings: settings, library: library, player: player, currentContext: { [weak self] in
            guard let self, isCurrent(), let book = library.books.first(where: { $0.id == bookID }) else { return nil }
            return listening.voicePickerContext(for: book)
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
        let location = player.location
        guard let bookID = location.readingBookID,
              let book = library.books.first(where: { $0.id == bookID }),
              book.fileType.supportsAudioConversion else { return }
        let chapter = pdfAnchor?.chapterIndex ?? chapterOverride
            ?? ReaderPlaybackPriorityChapter.index(bookID: book.id, location: location)
        let pageRatio = pdfAnchor == nil ? (pageRatioOverride ?? location.pageRatio) : nil
        // The book's language is resolved first (analysis off the main thread, cached per book), unless the
        // listener made an explicit per-job selection. The Play intent (chapter and page) was captured above,
        // before the asynchronous resolution; a newer request supersedes this one (languageResolution token).
        if optionsOverride == nil {
            resolveLanguageModelThenStart(book: book, owner: owner, chapterOverride: chapter,
                pageRatioOverride: .some(pageRatio), pdfAnchor: pdfAnchor, voiceChange: voiceChange)
            return
        }
        let options = optionsOverride ?? NarrationConversionOptions.current(for: settings.ttsPreferences)
        self.owner = owner
        recovery.begin { [weak self, weak owner] choice in
            guard let self, let owner, player.location.readingBookID == book.id else { return }
            let recovered = choice.map { options.recovering(with: $0.candidate, language: $0.language) } ?? options
            start(owner: owner, optionsOverride: recovered, chapterOverride: chapter,
                  pageRatioOverride: .some(pageRatio), pdfAnchor: pdfAnchor, voiceChange: voiceChange)
        }
        let chapters = LocalFulltextCache.inMemoryPayload(bookId: bookID)?.chapters ?? []
        let showsPlayer = voiceChange == nil
        observePlayback()
        listening.start(book: book, priority: chapter, pageRatio: pageRatio, catalog: [],
                        conversionOptions: options, presentsFullPlayer: showsPlayer,
                        chapterEstimates: chapters.isEmpty ? readerChapterEstimates(bookID)
                            : ChapterPlaybackTimeline.estimates(for: chapters),
                        voiceChange: voiceChange, pdfAnchor: pdfAnchor, owner: owner,
                        showsPlayerOnCompletion: showsPlayer)
    }

    private var languageResolution: UUID?

    private func resolveLanguageModelThenStart(book: BookEntity, owner: AnyObject, chapterOverride: Int?,
                                               pageRatioOverride: Double??, pdfAnchor: PDFReadingAudioMap.Anchor?,
                                               voiceChange: ReaderVoiceChange?) {
        let token = UUID()
        languageResolution = token
        resolvingBookID = book.id
        Task { [weak self, weak owner] in
            guard let self else { return }
            // Not handed over (superseded, cancelled alert, deallocated owner): the pending book is dropped.
            defer { if languageResolution == token || languageResolution == nil { resolvingBookID = nil } }
            let outcome = await LanguageModelPlayback.outcome(
                for: book, settings: settings, hasExplicitSelection: false, dependencies: .live(library: library))
            let stillWanted = { [weak self] in
                self?.languageResolution == token && self?.player.location.readingBookID == book.id
            }
            guard stillWanted(), let owner else { return }
            if case .missing = outcome {} else {
                // BOOK-LANGUAGE-PROFILE: warn about the profile's languages without a voice, before playing, never blocking.
                let dependencies = LanguageModelPlayback.Dependencies.live(library: library)
                Task { @MainActor [settings] in
                    PlatformFallbackNotice.showMissingProfileLanguages(
                        await LanguageModelPlayback.missingProfileLanguages(for: book, settings: settings, dependencies: dependencies))
                }
            }
            @MainActor func begin(_ options: ConversionOptions) {
                languageResolution = nil
                resolvingBookID = nil
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

    func cancel(ifReplacingBook incomingBookID: String? = nil, stopPlayer: Bool = true) {
        guard incomingBookID == nil || incomingBookID != listening.listeningBookID else { return }
        recovery.invalidate()
        languageResolution = nil
        resolvingBookID = nil
        guard listening.listeningJobID != nil else { return }
        listening.cancel()
        if stopPlayer {
            player.stop()
            player.clearConversionState()
        }
    }

    private func reportFailure(_ error: Error) {
        let location = player.location
        let snapshotID = player.snapshot?.jobId
        let controller = owner as? NSViewController
        let window = (controller?.isViewLoaded == true ? controller?.view.window : nil)
            ?? NSApplication.shared.keyWindow
        recovery.report(error, bookID: location.readingBookID, isVisible: { [weak window] in window?.isVisible == true },
            currentBookID: { [weak player] in
                guard let player, player.snapshot?.jobId == snapshotID else { return nil }
                return player.location.readingBookID
            }) { error in
                guard let window else { return }
                let alert = NSAlert()
                alert.messageText = L10n.string("bookDetail.listenStart")
                alert.informativeText = AppErrorReporter.message(error, context: "Reader listening")
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.beginSheetModal(for: window)
            }
    }
}
#endif
