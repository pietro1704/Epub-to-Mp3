import Foundation

extension LocalAudioArtifactStore {
    /// One chapter the listener asked to keep, on the store's zero-based reader axis.
    struct DownloadRequest: Equatable, Sendable {
        let bookID: String
        let bookTitle: String
        let author: String?
        let chapterIndex: Int
        let chapterTitle: String
        /// Characters of the chapter's text before this audio; 0 for a whole chapter.
        var textOffset = 0
    }

    /// Keeps `source` as the protected audio of one chapter and returns its size.
    ///
    /// The source is only read. Its copy is staged inside the store and published
    /// with an atomic replace, so an interrupted Download leaves either the
    /// previous file or the complete new one. A chapter that already plays from
    /// its canonical file is protected in place without copying, and audio that
    /// starts later in the chapter never replaces kept audio that covers more of it.
    func retainDownload(from source: URL, request: DownloadRequest) throws -> Int64 {
        try Task.checkCancellation()
        guard request.chapterIndex >= 0, request.textOffset >= 0 else {
            throw LocalAudioImportFiles.Failure.invalidIdentity
        }
        var manifest = try validatedManifest(bookID: request.bookID) ?? Manifest(
            schemaVersion: Self.schemaVersion, bookID: request.bookID,
            bookTitle: request.bookTitle, author: request.author, chapters: [], updatedAt: Date())
        let directory = files.chaptersDirectory(bookID: request.bookID)
        let relativePath = files.relativePath(for: request.chapterIndex)
        let destination = files.bookDirectory(bookID: request.bookID).appendingPathComponent(relativePath)
        try LocalAudioImportFiles.checkPath(destination, under: files.root)
        let existing = manifest.chapters.first { $0.index == request.chapterIndex }
        let keepsFullerAudio = existing.map {
            $0.state == .available && ($0.textOffset ?? 0) < request.textOffset
                && files.hasAudioFile(bookID: request.bookID, artifact: $0)
        } ?? false
        let inPlace = keepsFullerAudio
            || isCanonicalFile(source, bookID: request.bookID, chapterIndex: request.chapterIndex)
        let byteCount: Int64
        if inPlace {
            byteCount = try files.fileSize(at: destination)
            guard byteCount > 0 else { throw StoreError.invalidAudioFile(destination) }
        } else {
            let expected = try files.fileSize(at: source)
            guard expected > 0 else { throw StoreError.invalidAudioFile(source) }
            try files.createDirectoryIfNeeded(directory)
            let staging = directory.appendingPathComponent(".download-\(UUID().uuidString).mp3")
            defer { try? files.fileManager.removeItem(at: staging) }
            // copyItem clones on APFS, so keeping a converted chapter costs no second copy.
            try files.fileManager.copyItem(at: source, to: staging)
            byteCount = try files.fileSize(at: staging)
            guard byteCount == expected else { throw StoreError.invalidAudioFile(source) }
            try files.applyDownloadedFilePolicy(to: staging)
            try Task.checkCancellation()
            if files.fileManager.fileExists(atPath: destination.path) {
                _ = try files.fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try files.fileManager.moveItem(at: staging, to: destination)
            }
        }
        try files.applyDownloadedFilePolicy(to: destination)
        let now = Date()
        if let position = manifest.chapters.firstIndex(where: { $0.index == request.chapterIndex }) {
            if !inPlace {
                manifest.chapters[position].title = request.chapterTitle
                manifest.chapters[position].textOffset = request.textOffset > 0 ? request.textOffset : nil
            }
            manifest.chapters[position].state = .available
            manifest.chapters[position].retention = .downloaded
            manifest.chapters[position].byteCount = byteCount
            manifest.chapters[position].lastError = nil
            manifest.chapters[position].updatedAt = now
        } else {
            manifest.chapters.append(ChapterArtifact(
                index: request.chapterIndex, title: request.chapterTitle, state: .available,
                retention: .downloaded, textOffset: request.textOffset > 0 ? request.textOffset : nil,
                relativePath: relativePath, byteCount: byteCount,
                retryCount: 0, lastError: nil, updatedAt: now))
            manifest.chapters.sort { $0.index < $1.index }
        }
        manifest.updatedAt = now
        // Once the file is published, record it before honoring cancellation.
        try files.save(manifest)
        return byteCount
    }

    /// Chapters of a book that are protected downloads with audio on disk.
    func downloadedChapterIndices(bookID: String) throws -> Set<Int> {
        guard let manifest = try files.loadManifest(bookID: bookID) else { return [] }
        return Set(manifest.chapters.filter {
            $0.retention == .downloaded && $0.state == .available
                && files.hasAudioFile(bookID: bookID, artifact: $0)
        }.map(\.index))
    }

    /// Ends a Download. A kept copy of audio that plays from elsewhere is removed.
    /// When `playbackSource` is the canonical file itself, the listener is
    /// playing the only copy, so it stays as recreatable audio instead.
    func releaseDownload(bookID: String, chapterIndex: Int, playbackSource: URL?) throws {
        guard let manifest = try files.loadManifest(bookID: bookID),
              let artifact = manifest.chapters.first(where: { $0.index == chapterIndex }),
              artifact.retention == .downloaded else { return }
        guard let playbackSource,
              isCanonicalFile(playbackSource, bookID: bookID, chapterIndex: chapterIndex),
              files.hasAudioFile(bookID: bookID, artifact: artifact) else {
            try removeDownloadedAudio(bookID: bookID, chapterIndex: chapterIndex)
            return
        }
        var updated = manifest
        guard let position = updated.chapters.firstIndex(where: { $0.index == chapterIndex }) else { return }
        updated.chapters[position].retention = .temporary
        updated.chapters[position].playbackRetentionRequested = false
        updated.chapters[position].updatedAt = Date()
        updated.updatedAt = Date()
        try files.save(updated)
        try files.applyTemporaryFilePolicy(
            to: files.bookDirectory(bookID: bookID).appendingPathComponent(artifact.relativePath))
    }

    /// The book's manifest when it is this store's own, or nil when none exists.
    /// A manifest for another book, schema or file layout is never extended.
    func validatedManifest(bookID: String) throws -> Manifest? {
        guard !bookID.isEmpty, files.safePathComponent(bookID) == bookID else {
            throw LocalAudioImportFiles.Failure.invalidIdentity
        }
        let manifestURL = files.bookDirectory(bookID: bookID).appendingPathComponent("manifest.json")
        try LocalAudioImportFiles.checkPath(manifestURL, under: files.root)
        guard let manifest = try files.loadManifest(bookID: bookID) else { return nil }
        guard manifest.bookID == bookID, manifest.schemaVersion == Self.schemaVersion,
              Set(manifest.chapters.map(\.index)).count == manifest.chapters.count,
              manifest.chapters.allSatisfy({ $0.index >= 0 && $0.relativePath == files.relativePath(for: $0.index) }) else {
            throw LocalAudioImportFiles.Failure.destinationConflict
        }
        return manifest
    }

    private func isCanonicalFile(_ url: URL, bookID: String, chapterIndex: Int) -> Bool {
        guard url.isFileURL else { return false }
        let canonical = files.bookDirectory(bookID: bookID)
            .appendingPathComponent(files.relativePath(for: chapterIndex))
        return url.resolvingSymlinksInPath().standardizedFileURL.path
            == canonical.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
