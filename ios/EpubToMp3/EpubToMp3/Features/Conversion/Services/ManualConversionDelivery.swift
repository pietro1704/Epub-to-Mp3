import AVFoundation
import Foundation

/// What a finished manual conversion can be delivered as: the source book added to the
/// library with its audio, and the audio exported to a place the user picks.
enum ManualConversionDelivery {
    enum Layout: String, CaseIterable {
        case single, perChapter

        var titleKey: String { self == .single ? "convert.export.oneFile" : "convert.export.perChapter" }
    }

    enum Format: String, CaseIterable {
        case m4a, mp3

        var title: String { rawValue.uppercased() }
    }

    /// The audio a finished conversion can export.
    struct Audiobook: Equatable {
        struct Chapter: Equatable {
            let title: String
            let file: URL
        }

        let title: String
        let author: String?
        let cover: URL?
        let chapters: [Chapter]
    }

    /// Nil when the conversion produced no MP3 chapter, the only input the export accepts.
    static func audiobook(from snapshot: JobSnapshot, libraryBook: BookEntity?, source: URL) -> Audiobook? {
        let chapters: [Audiobook.Chapter] = snapshot.playableChapters.compactMap { chapter in
            guard let path = chapter.downloadUrl else { return nil }
            let file = URL(fileURLWithPath: path)
            guard file.pathExtension.lowercased() == "mp3" else { return nil }
            return .init(title: chapter.displayTitle, file: file)
        }
        guard !chapters.isEmpty else { return nil }
        let title = [libraryBook?.resolvedTitle, snapshot.bookTitle].compactMap { $0 }.first { !$0.isEmpty }
        return Audiobook(title: title ?? source.deletingPathExtension().lastPathComponent,
                         author: libraryBook?.author ?? snapshot.bookAuthor,
                         cover: snapshot.coverUrl.map { URL(fileURLWithPath: $0) },
                         chapters: chapters)
    }

    /// Adds the converted source and links the job, so the reader plays this audio.
    @MainActor
    @discardableResult
    static func addToLibrary(source: URL, jobID: String, library: LibraryStore) async throws -> BookEntity {
        let book = try await library.importBookAsync(from: source)
        library.recordConversion(jobId: jobID, for: book.id)
        return book
    }

    static func doneMessage(fileCount: Int) -> String {
        fileCount == 1 ? L10n.string("convert.export.done.one")
            : L10n.string("convert.export.done.other", fileCount)
    }

    /// Rust splits, names and joins the MP3 files. M4A uses Apple's AAC encoder on those
    /// same files, so both formats share chapter names and order. Never overwrites.
    static func export(_ book: Audiobook, layout: Layout, format: Format, to directory: URL,
                       adapter: ConverterFFIAdapter = ConverterFFIAdapter()) async throws -> [URL] {
        switch format {
        case .mp3:
            return try await exportMP3(book, layout: layout, to: directory, adapter: adapter)
        case .m4a:
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("ManualExport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let sources = try await exportMP3(book, layout: layout, to: staging, adapter: adapter)
            var written: [URL] = []
            do {
                for (offset, source) in sources.enumerated() {
                    try Task.checkCancellation()
                    let destination = unusedFile(named: source.deletingPathExtension().lastPathComponent,
                                                 extension: "m4a", in: directory)
                    let title = layout == .single ? book.title : book.chapters[offset].title
                    try await encodeM4A(source, to: destination, title: title, book: book)
                    written.append(destination)
                }
            } catch {
                // Only the files of this run are removed.
                written.forEach { try? FileManager.default.removeItem(at: $0) }
                throw error
            }
            return written
        }
    }

    private static func exportMP3(_ book: Audiobook, layout: Layout, to directory: URL,
                                  adapter: ConverterFFIAdapter) async throws -> [URL] {
        struct Request: Encodable {
            struct Chapter: Encodable {
                let title: String
                let path: String
            }

            let destination: String
            let layout: String
            let title: String
            let author: String?
            let cover: String?
            let chapters: [Chapter]
        }
        let request = try JSONEncoder().encode(Request(
            destination: directory.path, layout: layout.rawValue, title: book.title, author: book.author,
            cover: book.cover.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil },
            chapters: book.chapters.map { .init(title: $0.title, path: $0.file.path) }))
        return try await Task.detached(priority: .userInitiated) {
            try adapter.exportMP3(request: String(decoding: request, as: UTF8.self))
        }.value
    }

    private static func unusedFile(named stem: String, extension suffix: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(stem).\(suffix)")
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(attempt)).\(suffix)")
            attempt += 1
        }
        return candidate
    }

    private static func encodeM4A(_ source: URL, to destination: URL, title: String,
                                  book: Audiobook) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        func item(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            return item
        }
        var metadata = [item(.commonIdentifierTitle, title as NSString),
                        item(.commonIdentifierAlbumName, book.title as NSString)]
        if let author = book.author, !author.isEmpty {
            metadata.append(item(.commonIdentifierArtist, author as NSString))
        }
        if let cover = book.cover, let data = try? Data(contentsOf: cover) {
            metadata.append(item(.commonIdentifierArtwork, data as NSData))
        }
        session.metadata = metadata
        session.outputURL = destination
        session.outputFileType = .m4a
        // AVFoundation allows cancelling an export from any thread.
        nonisolated(unsafe) let exporter = session
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            exporter.cancelExport()
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            if session.status == .cancelled { throw CancellationError() }
            throw session.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}

/// What the iOS convert screen knows about the finished job it is showing.
struct ConvertDeliveryState {
    var jobID: String?
    var source: URL?
    var sourceID: String?
    var snapshot: JobSnapshot?
    var message: String?
    var isBusy = false

    var isReady: Bool { snapshot != nil }

    @MainActor
    func canAddToLibrary(library: LibraryStore) -> Bool {
        guard let sourceID else { return false }
        return !library.books.contains { $0.id == sourceID }
    }

    @MainActor
    func audiobook(library: LibraryStore) -> ManualConversionDelivery.Audiobook? {
        guard let snapshot, let source else { return nil }
        return ManualConversionDelivery.audiobook(
            from: snapshot, libraryBook: library.books.first { $0.id == sourceID }, source: source)
    }
}
