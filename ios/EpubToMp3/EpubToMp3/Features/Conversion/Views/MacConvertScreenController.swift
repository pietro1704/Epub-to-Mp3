#if os(macOS)
import AppKit
import Combine

/// A cheap identity for "the file has not been touched since it was hashed".
private struct SourceFingerprint: Equatable {
    let size: UInt64
    let modified: Date

    init?(_ file: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.size = size
        self.modified = modified
    }
}

@MainActor
final class MacConvertScreenController: NSViewController, NSTextFieldDelegate {
    let form = MacConversionForm()
    /// Opens the conversions list, which has no tab of its own.
    var onShowJobs: () -> Void = {}
    private let settings: AppSettings
    private let library: LibraryStore
    private let viewModel: ConvertViewModel
    private let resolveBookFile: (String) async throws -> URL
    /// Overrides the app-owned inbox that picked documents are copied into.
    private let inboxDirectory: URL?
    private let presentPronunciation: (String, NSViewController) -> Void
    private var observation: AnyCancellable?
    private var audioRemovalObservation: AnyCancellable?
    /// The library book whose conversion is running, and whether its audio was
    /// explicitly removed meanwhile; a removed book's job must not be recorded again.
    private var convertingBookID: String?
    private var audioRemovedDuringConversion = false
    private var selectionID = UUID()
    /// The inbox copy made for the current manual selection; removed when the
    /// selection is replaced or abandoned so picked files do not pile up.
    private var importedCopy: URL?
    /// Size and modification date seen when the source identity was last
    /// verified, so submit re-hashes the book only when the file changed.
    private var verifiedFingerprint: SourceFingerprint?
    private var conversionSelectionID: UUID?
    private var sourceError: String?
    private var resultSnapshot: JobSnapshot?
    private var resultDirectory: URL?
    private(set) var selectedBookID: String?
    /// The file the form currently holds; exposed so tests can observe copy lifetime.
    var currentSelectionForTesting: URL? { viewModel.selectedFile }
    private(set) var isPreparingSource = false

    init(settings: AppSettings, library: LibraryStore, viewModel: ConvertViewModel? = nil,
         resolveBookFile: ((String) async throws -> URL)? = nil,
         inboxDirectory: URL? = nil,
         presentPronunciation: ((String, NSViewController) -> Void)? = nil) {
        self.inboxDirectory = inboxDirectory
        self.settings = settings
        self.library = library
        self.viewModel = viewModel ?? ConvertViewModel()
        self.resolveBookFile = resolveBookFile ?? { try await library.openBookFileAsync(id: $0) }
        self.presentPronunciation = presentPronunciation ?? { BookPronunciationEditor.present(bookID: $0, on: $1) }
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("convert.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = form }

    override func viewDidLoad() {
        super.viewDidLoad()
        for (button, action) in [(form.pickFile, #selector(pickFile)), (form.pronunciation, #selector(editPronunciation)),
                                 (form.submit, #selector(startConversion)), (form.cancel, #selector(cancelConversion)),
                                 (form.revealResult, #selector(revealResult)), (form.history, #selector(showJobs))] {
            button.target = self
            button.action = action
        }
        form.engine.target = self
        form.engine.action = #selector(engineChanged)
        for button in [form.secondary, form.clearCache, form.forceReprocess, form.maxPerformance] {
            button.target = self
            button.action = #selector(optionsChanged)
        }
        for field in [form.voice, form.language, form.chapters] { field.delegate = self }
        updatePreferences()
        observation = viewModel.session.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        audioRemovalObservation = NotificationCenter.default.publisher(for: RustConversionOutputStore.willRemoveAudio)
            .sink { [weak self] notification in
                let bookID = notification.userInfo?["bookID"] as? String
                MainActor.assumeIsolated { self?.audioWillBeRemoved(bookID: bookID) }
            }
        refresh()
    }

    private func audioWillBeRemoved(bookID: String?) {
        guard let convertingBookID, bookID == nil || bookID == convertingBookID else { return }
        audioRemovedDuringConversion = true
        viewModel.cancel()
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if !viewModel.isSubmitting { updatePreferences() }
        refresh()
    }

    /// Library context conversion selects the exact book, restores form defaults
    /// and starts directly. A running manual job retains its source and options.
    func selectLibraryBook(_ bookID: String, startImmediately: Bool = true) async {
        _ = view
        guard !viewModel.isSubmitting else {
            // Never drop the request silently: the running conversion keeps the form.
            sourceError = L10n.string("convert.error.busyWithAnotherBook")
            refresh()
            return
        }
        if let book = library.books.first(where: { $0.id == bookID }), !book.fileType.supportsAudioConversion {
            _ = beginSourceSelection()
            isPreparingSource = false
            sourceError = L10n.string("convert.error.unsupportedBookType")
            refresh()
            return
        }
        let request = beginSourceSelection()
        resetOptions()
        do {
            let file = try await resolveBookFile(bookID)
            let identity = try await Task.detached { try BookContentIdentity.hash(of: file) }.value
            guard selectionID == request else { return }
            try Task.checkCancellation()
            guard identity == bookID else {
                throw EmbeddedConverterError.conversionFailed(L10n.string("library.error.changedWhileOpening"))
            }
            finishSourceSelection(file: file, bookID: identity)
            if startImmediately { await submit() }
        } catch {
            failSourceSelection(error, request: request)
        }
    }

    /// Files chosen outside the library are copied before the picker relinquishes
    /// security-scoped access, then identified by content for pronunciation rules.
    func selectDocument(_ url: URL) async {
        guard !viewModel.isSubmitting else { return }
        _ = view
        let request = beginSourceSelection()
        var imported: URL?
        do {
            let inbox = inboxDirectory
            let file = try await Task.detached {
                try ConvertViewModel.importForConversion(url, baseDirectory: inbox)
            }.value
            imported = file
            let identity = try await Task.detached { try BookContentIdentity.hash(of: file) }.value
            guard selectionID == request else {
                ConvertViewModel.discardImportedCopy(file, baseDirectory: inboxDirectory)
                return
            }
            try Task.checkCancellation()
            importedCopy = file
            finishSourceSelection(file: file, bookID: identity)
        } catch {
            if let imported { ConvertViewModel.discardImportedCopy(imported, baseDirectory: inboxDirectory) }
            failSourceSelection(error, request: request)
        }
    }

    private func beginSourceSelection() -> UUID {
        if let importedCopy {
            ConvertViewModel.discardImportedCopy(importedCopy, baseDirectory: inboxDirectory)
            self.importedCopy = nil
        }
        verifiedFingerprint = nil
        selectionID = UUID()
        isPreparingSource = true
        selectedBookID = nil
        viewModel.selectedFile = nil
        viewModel.recoverySelection = nil
        viewModel.recoveryLanguage = nil
        sourceError = nil
        resultSnapshot = nil
        resultDirectory = nil
        refresh()
        return selectionID
    }

    private func finishSourceSelection(file: URL, bookID: String) {
        verifiedFingerprint = SourceFingerprint(file)
        viewModel.selectedFile = file
        selectedBookID = bookID
        isPreparingSource = false
        refresh()
    }

    private func failSourceSelection(_ error: Error, request: UUID) {
        guard selectionID == request else { return }
        isPreparingSource = false
        selectedBookID = nil
        viewModel.selectedFile = nil
        sourceError = error is CancellationError ? nil
            : AppErrorReporter.message(error, context: "Select manual conversion source")
        refresh()
    }

    func submit() async {
        guard !isPreparingSource, !viewModel.isSubmitting, let file = viewModel.selectedFile,
              let bookID = selectedBookID else { return }
        view.window?.makeFirstResponder(nil)
        readOptions()
        let selection = selectionID
        isPreparingSource = true
        refresh()
        do {
            // The selection already hashed this exact file; hash again only if it changed.
            if let verified = verifiedFingerprint, SourceFingerprint(file) == verified {
                try Task.checkCancellation()
            } else {
                let currentIdentity = try await Task.detached { try BookContentIdentity.hash(of: file) }.value
                guard selectionID == selection else { return }
                try Task.checkCancellation()
                guard currentIdentity == bookID else {
                    throw EmbeddedConverterError.conversionFailed(L10n.string("library.error.changedWhileOpening"))
                }
            }
        } catch {
            failSourceSelection(error, request: selection)
            return
        }
        isPreparingSource = false
        conversionSelectionID = selection
        sourceError = nil
        resultSnapshot = nil
        resultDirectory = nil
        convertingBookID = bookID
        audioRemovedDuringConversion = false
        await viewModel.submit()
        let audioRemoved = audioRemovedDuringConversion
        convertingBookID = nil
        audioRemovedDuringConversion = false
        guard selectionID == selection, viewModel.selectedFile == file else { return }
        if !audioRemoved, let result = viewModel.session.result {
            do {
                resultSnapshot = try result.snapshot()
                resultDirectory = result.outputDirectory
                if library.books.contains(where: { $0.id == bookID }) {
                    library.recordConversion(jobId: result.jobID, for: bookID)
                }
            } catch {
                sourceError = AppErrorReporter.message(error, context: "Manual conversion result")
            }
        }
        refresh()
        await recoverIfNeeded(file: file, bookID: bookID, selection: selection)
    }

    private func recoverIfNeeded(file: URL, bookID: String, selection: UUID) async {
        guard let failure = viewModel.session.failure else { return }
        let request = viewModel.session.requestID
        let isCurrent = { [weak self] in
            guard let self else { return false }
            return self.selectionID == selection && self.viewModel.selectedFile == file
                && self.viewModel.session.requestID == request && !self.viewModel.isSubmitting
                && self.isViewLoaded && self.view.window != nil
        }
        if BookLanguageUncertain.decode(failure) != nil {
            if await BookLanguagePicker.recover(failure, bookID: bookID, isCurrent: isCurrent), isCurrent() {
                await submit()
            }
        } else if TtsLanguageMismatch.decode(failure) != nil,
                  let choice = await TtsRecoveryAlert.choose(for: failure, isCurrent: isCurrent), isCurrent() {
            viewModel.recoverySelection = choice.candidate
            viewModel.recoveryLanguage = choice.language
            await submit()
        }
    }

    private func updatePreferences() {
        viewModel.inheritedPreferences = settings.ttsPreferences
        if viewModel.usesPreferences { viewModel.engine = settings.primaryEngine }
        viewModel.modelsRoot = LocalSpeechModelReadiness.ttsModelsRoot()?.path
    }

    private func resetOptions() {
        viewModel.usesPreferences = true
        viewModel.allowSecondary = false
        viewModel.voice = ""
        viewModel.language = ""
        viewModel.chapters = ""
        viewModel.clearCache = false
        viewModel.forceReprocess = false
        viewModel.maxPerformance = false
        updatePreferences()
        form.voice.stringValue = ""
        form.language.stringValue = ""
        form.chapters.stringValue = ""
        for button in [form.clearCache, form.forceReprocess, form.maxPerformance] { button.state = .off }
    }

    private func readOptions() {
        viewModel.voice = form.voice.stringValue
        viewModel.language = form.language.stringValue
        viewModel.chapters = form.chapters.stringValue
        viewModel.clearCache = form.clearCache.state == .on
        viewModel.forceReprocess = form.forceReprocess.state == .on
        viewModel.maxPerformance = form.maxPerformance.state == .on
        viewModel.allowSecondary = !viewModel.usesPreferences && form.secondary.state == .on
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let busy = isPreparingSource || viewModel.isSubmitting
        form.fileLabel.stringValue = viewModel.selectedFile?.lastPathComponent ?? L10n.string("convert.noFilePicked")
        for control in form.editableControls { control.isEnabled = !busy }
        form.pronunciation.isEnabled = !busy && selectedBookID != nil
        form.submit.isEnabled = !busy && viewModel.selectedFile != nil
        form.submit.title = isPreparingSource ? L10n.string("convert.preparing")
            : ManualConversionPresentation.title(for: viewModel.session)
        form.cancel.isHidden = !viewModel.isSubmitting
        form.cancel.isEnabled = viewModel.isSubmitting && viewModel.session.phase != .cancelling
        form.engine.selectItem(at: viewModel.usesPreferences ? 0
            : (TtsSelection.selectableEngines.firstIndex(of: viewModel.engine).map { $0 + 1 } ?? 0))
        let canSelectSecondary = !viewModel.usesPreferences && viewModel.distinctManualSecondary != nil
        form.secondary.isEnabled = !busy && canSelectSecondary
        form.secondary.state = (viewModel.usesPreferences
            ? viewModel.inheritedPreferences?.secondary != nil : canSelectSecondary && viewModel.allowSecondary) ? .on : .off
        form.status.stringValue = ManualConversionPresentation.detail(for: viewModel.session) ?? ""
        form.failure.stringValue = sourceError ?? (conversionSelectionID == selectionID ? viewModel.error : nil) ?? ""
        form.result.stringValue = resultSnapshot.map { snapshot in
            ([L10n.string("convert.completed")] + snapshot.playableChapters.map(\.displayTitle)).joined(separator: "\n")
        } ?? ""
        form.revealResult.isHidden = resultDirectory == nil
        for label in [form.status, form.failure, form.result] { label.isHidden = label.stringValue.isEmpty }
    }

    @objc private func showJobs() { onShowJobs() }
    @objc private func pickFile() {
        guard !viewModel.isSubmitting, !isPreparingSource, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SupportedImportTypes.all
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            Task { @MainActor in await self?.selectDocument(file) }
        }
    }

    @objc private func editPronunciation() {
        guard !isPreparingSource, !viewModel.isSubmitting, let bookID = selectedBookID else { return }
        presentPronunciation(bookID, self)
    }

    @objc private func startConversion() { Task { [weak self] in await self?.submit() } }
    @objc private func cancelConversion() { viewModel.cancel(); refresh() }
    @objc private func revealResult() {
        guard let resultDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resultDirectory])
    }

    @objc private func engineChanged() {
        viewModel.usesPreferences = form.engine.indexOfSelectedItem == 0
        if !viewModel.usesPreferences {
            viewModel.engine = TtsSelection.selectableEngines[form.engine.indexOfSelectedItem - 1]
        }
        viewModel.allowSecondary = false
        refresh()
    }

    @objc private func optionsChanged() { readOptions(); refresh() }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === form.voice, viewModel.usesPreferences {
            viewModel.engine = viewModel.inheritedPreferences?.primary.engine ?? settings.primaryEngine
            viewModel.usesPreferences = false
            viewModel.allowSecondary = false
            form.secondary.state = .off
        }
        readOptions()
        refresh()
    }
}
#endif
