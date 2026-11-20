import Foundation
import os

/// Runs the legacy audio migration once per launch, off the main thread.
///
/// Storage removals stop it first, so an import in flight can never bring back
/// audio the listener just removed. A stopped run is not restarted in this
/// launch; the migration is idempotent and continues on the next one.
@MainActor
final class LegacyAudioMigrationSession {
    typealias Book = LegacyAudioMigrationCoordinator.Book

    static let shared = LegacyAudioMigrationSession()
    nonisolated private static let log = Logger(subsystem: "epub2mp3", category: "Storage")

    private var task: Task<Void, Never>?
    private var hasStarted = false

    /// The library's books, or nil while the library has not loaded: a failed
    /// load must never read as an empty library. A job recorded by more than
    /// one book is attributed to none of them.
    static func books(in library: LibraryStore) -> [Book]? {
        guard library.hasLoadedSuccessfully else { return nil }
        let uses = Dictionary(grouping: library.books.compactMap(\.lastJobId), by: { $0 }).mapValues(\.count)
        return library.books.map { book in
            Book(id: book.id, title: book.title, author: book.author,
                 jobID: book.lastJobId.flatMap { uses[$0] == 1 ? $0 : nil })
        }
    }

    /// Starts the migration the first time the books are known. The delay keeps
    /// its disk work out of the launch and first book open.
    func startIfNeeded(
        books: [Book]?,
        coordinator: @escaping @Sendable () -> LegacyAudioMigrationCoordinator = { .launch },
        delayNanoseconds: UInt64 = 10_000_000_000
    ) {
        guard !hasStarted, let books else { return }
        hasStarted = true
        task = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                let report = try await coordinator().run(books: books)
                Self.log.info("Legacy audio migration: \(Self.summary(of: report), privacy: .public)")
            } catch {
                // Stopped by a storage removal or by the process ending.
                Self.log.info("Legacy audio migration stopped before finishing")
            }
        }
    }

    /// Cancels a running migration and waits until it has let go of the files.
    func stop() async {
        hasStarted = true
        // The task stays in place until it has finished, so a second caller
        // waits for the same run instead of returning while it still works.
        task?.cancel()
        await task?.value
    }

    /// Counts only; book and job identifiers are never logged.
    nonisolated static func summary(of report: LegacyAudioMigrationCoordinator.Report) -> String {
        var counts: [String: Int] = [:]
        for outcome in Array(report.books.values) + Array(report.storeCopies.values) {
            switch outcome {
            case .complete: counts["complete", default: 0] += 1
            case .partial: counts["partial", default: 0] += 1
            case .noLegacyAudio: counts["none", default: 0] += 1
            case .unprovenMapping: counts["unproven", default: 0] += 1
            case .unreadable: counts["unreadable", default: 0] += 1
            }
        }
        counts["alreadyDone"] = report.skippedByVersion.count
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}

extension LegacyAudioMigrationCoordinator {
    /// The migration over the app's real stores. A job's chapter axis and files
    /// come from its persisted Rust conversion, never from the legacy manifest.
    static var launch: LegacyAudioMigrationCoordinator {
        LegacyAudioMigrationCoordinator(
            store: .shared, legacyRoot: AudiobookDownloadStorage.audiobooksRootLocation(), defaults: .standard,
            convertedChapters: { jobID in
                guard let snapshot = RustConversionCoordinator.persistedSnapshot(jobID: jobID),
                      let base = snapshot.chapterIndexBase else { return nil }
                var files: [Int: URL] = [:]
                var textOffsets: [Int: Int] = [:]
                for chapter in snapshot.playableChapters {
                    guard let path = chapter.downloadUrl, path.hasPrefix("/") else { return nil }
                    files[chapter.index] = URL(fileURLWithPath: path)
                    if let offset = chapter.textOffset, offset > 0 { textOffsets[chapter.index] = offset }
                }
                return ConvertedChapters(indexBase: base, files: files, textOffsets: textOffsets)
            })
    }
}
