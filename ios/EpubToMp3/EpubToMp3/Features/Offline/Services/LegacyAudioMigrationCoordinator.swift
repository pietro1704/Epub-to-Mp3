import Foundation

/// Moves each library book's legacy `Audiobooks/<jobId>` audio into the durable
/// `LocalAudioArtifactStore`, but only where the chapter mapping is proven.
///
/// For every chapter it copies and validates the audio into the store, and
/// removes the legacy copy only after the store verifiably keeps the same
/// bytes as a protected download (see `retireLegacyAudio`). A job whose chapter
/// axis is not declared, a chapter the job's conversion does not contain, and
/// any audio that fails a check stay untouched on disk and are examined again
/// on a later run.
struct LegacyAudioMigrationCoordinator {
    struct Book: Equatable, Sendable {
        let id: String
        let title: String
        let author: String?
        /// The conversion job the library recorded for this book.
        let jobID: String?
    }

    /// What a job's persisted conversion declares about its chapters.
    struct ConvertedChapters: Equatable, Sendable {
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
        /// The chapter index base is not proven, so nothing is guessed.
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
        guard let manifestURL = LegacyJobDirectory.directory(for: jobID, under: legacyRoot, operation: #function)?
            .appendingPathComponent("manifest.json") else { return .unreadable }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .noLegacyAudio }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(AudiobookManifest.self, from: data),
              manifest.jobId == jobID, !manifest.chapters.isEmpty else { return .unreadable }
        let mapping: [Int: Int]
        let convertedFiles: [Int: URL]?
        var textOffsets: [Int: Int] = [:]
        if ownAudio {
            // The store's own snapshots are on its zero-based axis by construction.
            mapping = Dictionary(uniqueKeysWithValues: manifest.chapters.compactMap { entry -> (Int, Int)? in
                entry.index >= 0 ? (entry.index, entry.index) : nil
            })
            convertedFiles = nil
        } else {
            guard let converted = await convertedChapters(jobID),
                  converted.indexBase == 0 || converted.indexBase == 1 else { return .unprovenMapping }
            // Only chapters the conversion itself contains are on a proven axis.
            mapping = Dictionary(uniqueKeysWithValues: manifest.chapters.compactMap { entry -> (Int, Int)? in
                entry.index >= converted.indexBase && converted.files[entry.index] != nil
                    ? (entry.index, entry.index - converted.indexBase) : nil
            })
            convertedFiles = converted.files
            textOffsets = converted.textOffsets
        }
        let identity = LocalAudioArtifactStore.LegacyImportIdentity(
            bookID: book.id, bookTitle: book.title, author: book.author, jobID: jobID,
            canonicalIndices: mapping, textOffsets: textOffsets)
        let imported: LocalAudioArtifactStore.LegacyImportReport
        let retired: LocalAudioArtifactStore.LegacyRetirementReport
        do {
            imported = try await store.importLegacyAudio(from: legacyRoot, identity: identity) {
                onProgress(book.id, $0)
            }
            retired = try await store.retireLegacyAudio(
                from: legacyRoot, identity: identity, convertedFiles: convertedFiles)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unreadable
        }
        let copied = imported.chapters.values.filter { $0 == .imported }.count
        let present = imported.chapters.values.filter { $0 == .alreadyPresent }.count
        guard retired.remaining == 0 else {
            return .partial(imported: copied, alreadyPresent: present, deferred: retired.remaining)
        }
        // Only a job with nothing left in the legacy layout is recorded as done.
        defaults.set(true, forKey: Self.markerKey(bookID: book.id, jobID: jobID))
        return .complete(imported: copied, alreadyPresent: present)
    }
}
