import Foundation

extension LocalAudioArtifactStore {
    /// The caller must resolve one book/job association from loaded library or
    /// ownership records and supply the proven legacy -> reader chapter mapping.
    /// Missing entries are deferred; neither titles nor numeric index heuristics
    /// establish identity. This operation does not activate a launch migration.
    struct LegacyImportIdentity: Sendable {
        let bookID: String
        let bookTitle: String
        let author: String?
        let jobID: String
        let canonicalIndices: [Int: Int]
    }

    enum LegacyImportOutcome: Equatable, Sendable {
        case imported
        case alreadyPresent
        case unmapped
        case conflict
        case invalidSource
        case invalidAudio
        case failed(String)
    }

    /// Outcomes use the original manifest indices so deferred legacy entries
    /// remain identifiable even when no canonical mapping exists.
    struct LegacyImportReport: Equatable, Sendable {
        var chapters: [Int: LegacyImportOutcome] = [:]
    }

    enum LegacyImportProgress: Equatable, Sendable {
        case copied(legacyChapterIndex: Int, bytes: Int64)
        case decoded(legacyChapterIndex: Int, frames: Int64)
    }

    /// Copies retained audio into the durable store without removing any legacy
    /// file, key or manifest. Before wiring this into launch, coordinate legacy
    /// writers and compose partial store snapshots with remaining Rust artifacts.
    /// That coordinator can forward progress to its migration reporting; these
    /// events describe work performed, never durable per-chapter completion.
    func importLegacyAudio(
        from legacyRoot: URL, identity: LegacyImportIdentity,
        onProgress: @Sendable (LegacyImportProgress) -> Void = { _ in }
    ) throws -> LegacyImportReport {
        try Task.checkCancellation()
        let sourceRoot = legacyRoot.standardizedFileURL
        guard LegacyJobDirectory.isSafeComponent(identity.jobID), !identity.bookID.isEmpty,
              files.safePathComponent(identity.bookID) == identity.bookID,
              identity.canonicalIndices.keys.allSatisfy({ $0 >= 0 }),
              identity.canonicalIndices.values.allSatisfy({ $0 >= 0 }),
              Set(identity.canonicalIndices.values).count == identity.canonicalIndices.count else {
            throw LocalAudioImportFiles.Failure.invalidIdentity
        }
        let sourceDirectory = sourceRoot.appendingPathComponent(identity.jobID, isDirectory: true)
        let sourceManifestURL = sourceDirectory.appendingPathComponent("manifest.json")
        try LocalAudioImportFiles.requireRegularFile(sourceManifestURL, under: sourceRoot)
        let sourceManifestBytes = try Data(contentsOf: sourceManifestURL)
        let sourceManifest = try JSONDecoder().decode(AudiobookManifest.self, from: sourceManifestBytes)
        guard sourceManifest.jobId == identity.jobID,
              Set(sourceManifest.chapters.map(\.index)).count == sourceManifest.chapters.count,
              Set(sourceManifest.chapters.map(\.mp3FileName)).count == sourceManifest.chapters.count else {
            throw LocalAudioImportFiles.Failure.invalidIdentity
        }
        let destination = files.bookDirectory(bookID: identity.bookID)
        let sourcePath = sourceRoot.resolvingSymlinksInPath().path
        let destinationPath = files.root.resolvingSymlinksInPath().path
        guard sourcePath != destinationPath, !sourcePath.hasPrefix(destinationPath + "/"),
              !destinationPath.hasPrefix(sourcePath + "/") else {
            throw LocalAudioImportFiles.Failure.unsafePath
        }
        try LocalAudioImportFiles.checkPath(destination.appendingPathComponent("manifest.json"), under: files.root)
        _ = try importDestinationManifest(identity)
        var report = LegacyImportReport()
        for chapter in sourceManifest.chapters {
            try Task.checkCancellation()
            guard let canonicalIndex = identity.canonicalIndices[chapter.index] else {
                report.chapters[chapter.index] = .unmapped
                continue
            }
            do {
                report.chapters[chapter.index] = try importLegacyChapter(
                    chapter, canonicalIndex: canonicalIndex, sourceRoot: sourceRoot,
                    sourceDirectory: sourceDirectory, sourceManifestURL: sourceManifestURL,
                    sourceManifestBytes: sourceManifestBytes, identity: identity, onProgress: onProgress)
            } catch is CancellationError {
                throw CancellationError()
            } catch LocalAudioImportFiles.Failure.destinationConflict {
                report.chapters[chapter.index] = .conflict
            } catch LocalAudioImportFiles.Failure.invalidAudio {
                report.chapters[chapter.index] = .invalidAudio
            } catch is LocalAudioImportFiles.Failure {
                report.chapters[chapter.index] = .invalidSource
            } catch {
                report.chapters[chapter.index] = .failed(error.localizedDescription)
            }
        }
        return report
    }

    private func importDestinationManifest(_ identity: LegacyImportIdentity) throws -> Manifest? {
        let manifestURL = files.bookDirectory(bookID: identity.bookID).appendingPathComponent("manifest.json")
        try LocalAudioImportFiles.checkPath(manifestURL, under: files.root)
        guard let manifest = try files.loadManifest(bookID: identity.bookID) else { return nil }
        guard manifest.bookID == identity.bookID, manifest.schemaVersion == Self.schemaVersion,
              Set(manifest.chapters.map(\.index)).count == manifest.chapters.count,
              manifest.chapters.allSatisfy({ $0.index >= 0 && $0.relativePath == files.relativePath(for: $0.index) }) else {
            throw LocalAudioImportFiles.Failure.destinationConflict
        }
        return manifest
    }

    private func importLegacyChapter(
        _ chapter: AudiobookManifest.ChapterEntry, canonicalIndex: Int,
        sourceRoot: URL, sourceDirectory: URL, sourceManifestURL: URL,
        sourceManifestBytes: Data, identity: LegacyImportIdentity,
        onProgress: @Sendable (LegacyImportProgress) -> Void
    ) throws -> LegacyImportOutcome {
        guard LocalAudioImportFiles.isComponent(chapter.mp3FileName), chapter.mp3Bytes > 0 else {
            throw LocalAudioImportFiles.Failure.invalidIdentity
        }
        let source = sourceDirectory.appendingPathComponent("chapters").appendingPathComponent(chapter.mp3FileName)
        try LocalAudioImportFiles.requireRegularFile(source, under: sourceRoot)
        let directory = files.chaptersDirectory(bookID: identity.bookID)
        try LocalAudioImportFiles.checkPath(directory, under: files.root)
        try files.createDirectoryIfNeeded(directory)
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString).mp3")
        defer { try? files.fileManager.removeItem(at: staging) }
        let copied = try LocalAudioImportFiles.fingerprint(source, copyingTo: staging) { bytes in
            onProgress(.copied(legacyChapterIndex: chapter.index, bytes: bytes))
        }
        guard copied.byteCount == chapter.mp3Bytes else { throw LocalAudioImportFiles.Failure.sourceChanged }
        try LocalAudioImportFiles.validateAudio(staging) { frames in
            onProgress(.decoded(legacyChapterIndex: chapter.index, frames: frames))
        }
        try LocalAudioImportFiles.requireRegularFile(source, under: sourceRoot)
        try LocalAudioImportFiles.requireRegularFile(sourceManifestURL, under: sourceRoot)
        guard try LocalAudioImportFiles.fingerprint(source) == copied,
              try Data(contentsOf: sourceManifestURL) == sourceManifestBytes else {
            throw LocalAudioImportFiles.Failure.sourceChanged
        }
        try Task.checkCancellation()
        var manifest = try importDestinationManifest(identity) ?? Manifest(
            schemaVersion: Self.schemaVersion, bookID: identity.bookID,
            bookTitle: identity.bookTitle, author: identity.author, chapters: [], updatedAt: Date())
        let relativePath = files.relativePath(for: canonicalIndex)
        let destination = files.bookDirectory(bookID: identity.bookID).appendingPathComponent(relativePath)
        try LocalAudioImportFiles.checkPath(destination, under: files.root)
        if let existing = manifest.chapters.first(where: { $0.index == canonicalIndex }) {
            // Never replace a pending/newer state or a different audio file.
            guard existing.state == .available, existing.relativePath == relativePath,
                  existing.byteCount == copied.byteCount else {
                throw LocalAudioImportFiles.Failure.destinationConflict
            }
            try LocalAudioImportFiles.requireRegularFile(destination, under: files.root)
            guard try LocalAudioImportFiles.fingerprint(destination) == copied else {
                throw LocalAudioImportFiles.Failure.destinationConflict
            }
            // A previous atomic manifest write may have succeeded before a file
            // policy error. Retry those policies without changing newer metadata.
            if existing.retention == .downloaded {
                try files.applyDownloadedFilePolicy(to: destination)
            } else {
                try files.applyTemporaryFilePolicy(to: destination)
            }
            try files.applyManifestFilePolicy(
                to: files.bookDirectory(bookID: identity.bookID).appendingPathComponent("manifest.json"))
            return .alreadyPresent
        }
        if files.fileManager.fileExists(atPath: destination.path) {
            // Recover a file published before a failed manifest save only if its
            // bytes are exactly the newly validated source. Never overwrite it.
            try LocalAudioImportFiles.requireRegularFile(destination, under: files.root)
            guard try LocalAudioImportFiles.fingerprint(destination) == copied else {
                throw LocalAudioImportFiles.Failure.destinationConflict
            }
        } else {
            try files.applyDownloadedFilePolicy(to: staging)
            try Task.checkCancellation()
            try files.fileManager.moveItem(at: staging, to: destination)
        }
        try files.applyDownloadedFilePolicy(to: destination)
        manifest.chapters.append(ChapterArtifact(
            index: canonicalIndex, title: chapter.title, state: .available, retention: .downloaded,
            relativePath: relativePath, byteCount: copied.byteCount, retryCount: 0,
            lastError: nil, updatedAt: chapter.downloadedAt))
        manifest.chapters.sort { $0.index < $1.index }
        manifest.updatedAt = Date()
        // After publication starts, finish this chapter's manifest before honoring
        // cancellation. Either retry sees a complete entry or an identical orphan.
        try files.save(manifest)
        guard try importDestinationManifest(identity) == manifest else {
            throw LocalAudioImportFiles.Failure.destinationConflict
        }
        return .imported
    }
}
