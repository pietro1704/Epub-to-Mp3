import Foundation

/// Moves each library book's legacy `Audiobooks/<jobId>` audio into the durable
/// `LocalAudioArtifactStore`, but only where book and chapter are proven.
///
/// A legacy chapter moves only when all of this holds:
/// - the job's own ownership record names this book;
/// - the job's chapter indices are on the reader's axis;
/// - the legacy file is byte-identical to the job's converted file for the same
///   chapter index, which is what a Download copied.
///
/// Such a chapter is copied and validated into the store, and its legacy copy
/// is removed only after the store verifiably keeps the same bytes as a
/// protected download and playback can use the converted file (see
/// `retireLegacyAudio`). Everything else stays untouched on disk and is
/// examined again on a later run. Chapters are processed one at a time, so the
/// store stays available to the listener between them.
struct LegacyAudioMigrationCoordinator {
    struct Book: Equatable, Sendable {
        let id: String
        let title: String
        let author: String?
        /// The conversion job the library recorded for this book.
        let jobID: String?
    }

    /// What a job's persisted conversion declares about itself.
    struct ConvertedChapters: Equatable, Sendable {
        /// The book the job's ownership record names, when it has one.
        let bookID: String?
        /// Whether the chapter indices are the reader's, not the converter's own.
        let usesReaderAxis: Bool
        /// The chapter index base (0 or 1) the conversion declares.
        let indexBase: Int
        /// The job's chapter files, by the job's own chapter index.
        let files: [Int: URL]
        /// Characters of chapter text before the audio, for chapters whose
        /// audio starts inside the chapter.
        var textOffsets: [Int: Int] = [:]
    }

    enum JobOutcome: Equatable, Sendable {
        /// Every legacy chapter is in the store and its legacy copy is gone.
        case complete(imported: Int, alreadyPresent: Int)
        /// Some chapters are still in the legacy layout.
        case partial(imported: Int, alreadyPresent: Int, deferred: Int)
        /// There is no legacy audio to move for this job.
        case noLegacyAudio
        /// Book or chapter axis is not proven, so nothing is guessed.
        case unprovenMapping
        /// The legacy manifest could not be read or does not match its job.
        case unreadable
    }

    struct Report: Equatable, Sendable {
        /// The job the library recorded for each book.
        var books: [String: JobOutcome] = [:]
        /// Legacy copies of audio that already played from the store itself.
        var storeCopies: [String: JobOutcome] = [:]
        var skippedByVersion: [String] = []
    }

    /// Bumped when the rules change so finished jobs are examined again.
    static let version = 1

    let store: LocalAudioArtifactStore
    let legacyRoot: URL
    let defaults: UserDefaults
    /// The job's persisted conversion, or nil when none can be read.
    let convertedChapters: @Sendable (String) async -> ConvertedChapters?
    /// The readiness test playback applies to a chapter's own file.
    let isPlayable: @Sendable (URL) -> Bool

    private static func markerKey(bookID: String, jobID: String) -> String {
        "legacyAudioMigration.v\(version).\(bookID).\(jobID)"
    }

    func run(
        books: [Book],
        onProgress: @Sendable (String, LocalAudioArtifactStore.LegacyImportProgress) -> Void = { _, _ in }
    ) async throws -> Report {
        var report = Report()
        for book in books {
            try Task.checkCancellation()
            if let jobID = book.jobID, LegacyJobDirectory.isSafeComponent(jobID) {
                if defaults.bool(forKey: Self.markerKey(bookID: book.id, jobID: jobID)) {
                    report.skippedByVersion.append(book.id)
                } else {
                    report.books[book.id] = try await migrate(book, jobID: jobID, ownAudio: false, onProgress: onProgress)
                }
            } else {
                report.books[book.id] = .noLegacyAudio
            }
            // A Download of audio that played from the store was copied under this job id.
            let storeJobID = "embedded-\(book.id)"
            guard storeJobID != book.jobID, LegacyJobDirectory.isSafeComponent(storeJobID),
                  !defaults.bool(forKey: Self.markerKey(bookID: book.id, jobID: storeJobID)) else { continue }
            let outcome = try await migrate(book, jobID: storeJobID, ownAudio: true, onProgress: onProgress)
            if outcome != .noLegacyAudio { report.storeCopies[book.id] = outcome }
        }
        return report
    }

    private func migrate(
        _ book: Book, jobID: String, ownAudio: Bool,
        onProgress: @Sendable (String, LocalAudioArtifactStore.LegacyImportProgress) -> Void
    ) async throws -> JobOutcome {
        guard let directory = LegacyJobDirectory.directory(for: jobID, under: legacyRoot, operation: #function) else {
            return .unreadable
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .noLegacyAudio }
        guard let manifest = Self.manifest(at: manifestURL, jobID: jobID), !manifest.chapters.isEmpty else {
            return .unreadable
        }
        var converted: ConvertedChapters?
        if !ownAudio {
            guard let declared = await convertedChapters(jobID), declared.bookID == book.id,
                  declared.usesReaderAxis, declared.indexBase == 0 || declared.indexBase == 1 else {
                return .unprovenMapping
            }
            converted = declared
        }
        var copied = 0, present = 0
        for entry in manifest.chapters {
            try Task.checkCancellation()
            let canonicalIndex: Int
            var convertedFile: [Int: URL]?
            if let converted {
                // A Download copied the converted file, so only identical bytes
                // prove that this entry is that chapter.
                guard entry.index >= converted.indexBase, let file = converted.files[entry.index],
                      Self.sameBytes(file, Self.chapterFile(entry, in: directory)) else { continue }
                canonicalIndex = entry.index - converted.indexBase
                convertedFile = [entry.index: file]
            } else {
                // The store's own snapshots are on its zero-based axis by construction.
                guard entry.index >= 0 else { continue }
                canonicalIndex = entry.index
            }
            let identity = LocalAudioArtifactStore.LegacyImportIdentity(
                bookID: book.id, bookTitle: book.title, author: book.author, jobID: jobID,
                canonicalIndices: [entry.index: canonicalIndex],
                textOffsets: (converted?.textOffsets[entry.index]).map { [entry.index: $0] } ?? [:])
            do {
                let imported = try await store.importLegacyAudio(from: legacyRoot, identity: identity) {
                    onProgress(book.id, $0)
                }
                switch imported.chapters[entry.index] {
                case .imported: copied += 1
                case .alreadyPresent: present += 1
                default: break
                }
                _ = try await store.retireLegacyAudio(
                    from: legacyRoot, identity: identity, convertedFiles: convertedFile, isPlayable: isPlayable)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .unreadable
            }
            // Let the listener's own store requests in between two chapters.
            await Task.yield()
        }
        let remaining = FileManager.default.fileExists(atPath: manifestURL.path)
            ? (Self.manifest(at: manifestURL, jobID: jobID)?.chapters.count ?? manifest.chapters.count) : 0
        guard remaining == 0 else {
            return .partial(imported: copied, alreadyPresent: present, deferred: remaining)
        }
        // Only a job with nothing left in the legacy layout is recorded as done.
        defaults.set(true, forKey: Self.markerKey(bookID: book.id, jobID: jobID))
        return .complete(imported: copied, alreadyPresent: present)
    }

    private static func manifest(at url: URL, jobID: String) -> AudiobookManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(AudiobookManifest.self, from: data),
              manifest.jobId == jobID else { return nil }
        return manifest
    }

    private static func chapterFile(_ entry: AudiobookManifest.ChapterEntry, in directory: URL) -> URL? {
        guard LocalAudioImportFiles.isComponent(entry.mp3FileName) else { return nil }
        return directory.appendingPathComponent("chapters").appendingPathComponent(entry.mp3FileName)
    }

    private static func sameBytes(_ converted: URL, _ legacy: URL?) -> Bool {
        guard let legacy, let first = try? LocalAudioImportFiles.fingerprint(converted),
              let second = try? LocalAudioImportFiles.fingerprint(legacy) else { return false }
        return first.byteCount > 0 && first == second
    }
}
