import Foundation

/// Imports each library book's legacy `Audiobooks/<jobId>` audio into the
/// durable `LocalAudioArtifactStore`, but only where the chapter mapping is
/// proven. It never removes or rewrites a legacy file, key or manifest, and a
/// job whose chapter index base is not declared stays untouched on disk.
///
/// This type is not wired to launch: the Download writer and the playback and
/// TOC readers still use the legacy layout, so running it at launch would only
/// duplicate audio. It is the tested seam the cutover builds on.
struct LegacyAudioMigrationCoordinator {
    struct Book: Equatable, Sendable {
        let id: String
        let title: String
        let author: String?
        /// The conversion job the library recorded for this book.
        let jobID: String?
    }

    enum JobOutcome: Equatable, Sendable {
        /// Every legacy chapter is now in the store (copied or already there).
        case complete(imported: Int, alreadyPresent: Int)
        /// Some chapters are not in the store yet; the legacy files remain.
        case partial(imported: Int, alreadyPresent: Int, deferred: Int)
        /// There is no legacy audio to import for this book.
        case noLegacyAudio
        /// The chapter index base is not proven, so nothing is guessed.
        case unprovenMapping
        /// The legacy manifest could not be read or does not match its job.
        case unreadable
    }

    struct Report: Equatable, Sendable {
        var books: [String: JobOutcome] = [:]
        var skippedByVersion: [String] = []
    }

    /// Bumped when the import rules change so books are examined again.
    static let version = 1

    let store: LocalAudioArtifactStore
    let legacyRoot: URL
    let defaults: UserDefaults
    /// The chapter index base (0 or 1) that the job's persisted conversion
    /// snapshot declares, or nil when it declares none.
    let provenIndexBase: @Sendable (String) async -> Int?

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
            guard let jobID = book.jobID, LegacyJobDirectory.isSafeComponent(jobID) else {
                report.books[book.id] = .noLegacyAudio
                continue
            }
            if defaults.bool(forKey: Self.markerKey(bookID: book.id, jobID: jobID)) {
                report.skippedByVersion.append(book.id)
                continue
            }
            report.books[book.id] = try await migrate(book, jobID: jobID, onProgress: onProgress)
        }
        return report
    }

    private func migrate(
        _ book: Book, jobID: String,
        onProgress: @Sendable (String, LocalAudioArtifactStore.LegacyImportProgress) -> Void
    ) async throws -> JobOutcome {
        guard let manifestURL = LegacyJobDirectory.directory(for: jobID, under: legacyRoot, operation: #function)?
            .appendingPathComponent("manifest.json") else { return .unreadable }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .noLegacyAudio }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(AudiobookManifest.self, from: data),
              manifest.jobId == jobID, !manifest.chapters.isEmpty else { return .unreadable }
        guard let base = await provenIndexBase(jobID), base == 0 || base == 1 else { return .unprovenMapping }
        let mapping = Dictionary(uniqueKeysWithValues: manifest.chapters.compactMap { entry -> (Int, Int)? in
            entry.index >= base ? (entry.index, entry.index - base) : nil
        })
        let identity = LocalAudioArtifactStore.LegacyImportIdentity(
            bookID: book.id, bookTitle: book.title, author: book.author, jobID: jobID, canonicalIndices: mapping)
        let result: LocalAudioArtifactStore.LegacyImportReport
        do {
            result = try await store.importLegacyAudio(from: legacyRoot, identity: identity) {
                onProgress(book.id, $0)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unreadable
        }
        var imported = 0, present = 0, deferred = 0
        for outcome in result.chapters.values {
            switch outcome {
            case .imported: imported += 1
            case .alreadyPresent: present += 1
            case .unmapped, .conflict, .invalidSource, .invalidAudio, .failed: deferred += 1
            }
        }
        guard deferred == 0 else { return .partial(imported: imported, alreadyPresent: present, deferred: deferred) }
        // Only a fully imported job is recorded; anything else is examined again later.
        defaults.set(true, forKey: Self.markerKey(bookID: book.id, jobID: jobID))
        return .complete(imported: imported, alreadyPresent: present)
    }
}
