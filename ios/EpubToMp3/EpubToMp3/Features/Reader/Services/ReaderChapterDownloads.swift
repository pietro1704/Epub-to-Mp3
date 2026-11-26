import Foundation

/// Keeps explicit chapter downloads separate from listening transport.
@MainActor
final class ReaderChapterDownloads {
    /// Whether a requested download is still being prepared.
    var onBusyChange: ((Bool) -> Void)?
    /// A failure to show, as title and message.
    var onError: ((String, String) -> Void)?
    var isBusy: Bool { task != nil }
    var bookID: String { book.id }
    private let book: BookEntity
    private let library: LibraryStore
    private let settings: AppSettings
    private let snapshot: JobSnapshot?
    private var task: Task<Void, Never>?
    private var activeRemovals = 0

    init(book: BookEntity, library: LibraryStore, settings: AppSettings, snapshot: JobSnapshot?) {
        self.book = book
        self.library = library
        self.settings = settings
        self.snapshot = snapshot
    }

    func start(_ indices: [Int]) {
        guard task == nil, activeRemovals == 0 else { return }
        let chapters = Set(indices.filter { $0 >= 0 }).sorted()
        guard !chapters.isEmpty else { return }
        task = Task {
            defer {
                task = nil
                onBusyChange?(false)
            }
            do {
                var bookURL: URL?
                var hasSecurityScope = false
                defer { if hasSecurityScope { bookURL?.stopAccessingSecurityScopedResource() } }
                // The book's language decides the narration (cached analysis), like a listening request.
                let options = try await LanguageModelPlayback.conversionOptions(
                    for: book, settings: settings, dependencies: .live(library: library))
                for index in chapters {
                    try Task.checkCancellation()
                    guard library.books.contains(where: { $0.id == book.id }) else { return }
                    if try await keepLocalChapter(index) { continue }
                    guard let position = Int32(exactly: index) else { throw CocoaError(.fileReadCorruptFile) }
                    if bookURL == nil {
                        let file = try await library.openBookFileAsync(id: book.id)
                        bookURL = file
                        hasSecurityScope = file.startAccessingSecurityScopedResource()
                    }
                    guard let bookURL else { throw CocoaError(.fileNoSuchFile) }
                    let control = try RustConversionCoordinator.makePlaybackControl()
                    let result = try await withTaskCancellationHandler {
                        try await RustConversionCoordinator.executeStreaming(
                            bookURL: bookURL, jobID: UUID().uuidString, chapterStart: position,
                            chapterEnd: position, control: control, options: options,
                            onProgress: nil, onChapterCompleted: nil, onAudioChunk: nil)
                    } onCancel: { control.cancel() }
                    try Task.checkCancellation()
                    guard library.books.contains(where: { $0.id == book.id }),
                          let chapter = try result.snapshot().playableChapters.first(where: { $0.index == index }),
                          let source = chapter.downloadUrl.flatMap({ AudiobookChapterTransfer.resolve(path: $0, base: nil) }),
                          source.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
                    try await keep(source, chapter: chapter)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                report(error)
            }
        }
        onBusyChange?(true)
    }

    private func keepLocalChapter(_ index: Int) async throws -> Bool {
        if let local = try await LocalAudioArtifactStore.shared.playableSnapshot(
            bookID: book.id, engine: "local", voice: "auto", language: nil),
           try await keepChapter(in: local, index: index) { return true }
        guard let snapshot, let owner = await RetainedAudioOwner.resolve(snapshot),
              owner.bookID == book.id, owner.indexBase == 0 else { return false }
        return try await keepChapter(in: snapshot, index: index)
    }

    private func keepChapter(in snapshot: JobSnapshot, index: Int) async throws -> Bool {
        guard let chapter = snapshot.playableChapters.first(where: { $0.index == index && ($0.textOffset ?? 0) == 0 }),
              let source = chapter.downloadUrl.flatMap({ AudiobookChapterTransfer.resolve(path: $0, base: nil) }),
              source.isFileURL, FileManager.default.fileExists(atPath: source.path) else { return false }
        try await keep(source, chapter: chapter)
        return true
    }

    private func keep(_ source: URL, chapter: JobSnapshot.Chapter) async throws {
        _ = try await LocalAudioArtifactStore.shared.retainDownload(from: source, request: .init(
            bookID: book.id, bookTitle: book.resolvedTitle, author: book.author,
            chapterIndex: chapter.index, chapterTitle: chapter.displayTitle,
            textOffset: max(0, chapter.textOffset ?? 0)), requireVisibleCopy: true)
    }

    func cancel() { task?.cancel() }

    func remove(chapter: Int?) async {
        activeRemovals += 1
        defer { activeRemovals -= 1 }
        if let task {
            task.cancel()
            await task.value
        }
        if let snapshot, let owner = await RetainedAudioOwner.resolve(snapshot),
           owner.bookID == book.id, owner.indexBase == 0 {
            if let chapter {
                await AudiobookDownloads.shared.removeDownload(snapshot: snapshot, chapterIndex: chapter)
            } else {
                await AudiobookDownloads.shared.clearDownloads(snapshot: snapshot)
            }
        }
        do {
            try await LocalAudioArtifactStore.shared.withdrawDownloadsFromFiles(bookID: book.id, chapterIndex: chapter)
        } catch {
            report(error, context: "Remove download", title: L10n.string("settings.storageRemovalFailedTitle"))
        }
    }

    private func report(_ error: Error, context: String = "Chapter download",
                        title: String = L10n.string("player.downloadFailed")) {
        onError?(title, AppErrorReporter.message(error, context: context))
    }
}
