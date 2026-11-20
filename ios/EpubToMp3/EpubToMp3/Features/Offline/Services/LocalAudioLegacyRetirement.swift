import Foundation

extension LocalAudioArtifactStore {
    enum LegacyRetirementOutcome: Equatable, Sendable {
        /// The legacy copy is gone and the store keeps the audio as a protected download.
        case retired
        /// The store does not hold these exact bytes as available audio.
        case notImported
        /// The file playback uses for this chapter is not proven playable.
        case playbackUnproven
        case failed(String)
    }

    /// Outcomes use the legacy manifest indices, like `LegacyImportReport`.
    struct LegacyRetirementReport: Equatable, Sendable {
        var chapters: [Int: LegacyRetirementOutcome] = [:]
        /// Legacy chapters still listed by the job's manifest afterwards.
        var remaining = 0
    }

    /// Removes legacy copies of audio this store verifiably keeps, after `importLegacyAudio`.
    ///
    /// A legacy file is removed only when all of this holds, checked again here:
    /// - the store has the chapter as available audio with exactly the same bytes;
    /// - that chapter is, or is first made, a protected download, because the
    ///   legacy copy was the listener's explicit Download;
    /// - the file playback uses once the copy is gone is proven: for a converted
    ///   job its own chapter file in `convertedFiles`, identical to the copy or
    ///   decodable to its end; for the store's own audio (`convertedFiles` nil)
    ///   the store file that was just compared.
    ///
    /// The file goes first and its manifest entry after, so an interruption leaves
    /// an entry without a file; the next run recognizes and drops such an entry.
    /// Everything else in the job folder, including reader text, is left alone.
    func retireLegacyAudio(
        from legacyRoot: URL, identity: LegacyImportIdentity, convertedFiles: [Int: URL]?
    ) throws -> LegacyRetirementReport {
        try Task.checkCancellation()
        let sourceRoot = legacyRoot.standardizedFileURL
        guard LegacyJobDirectory.isSafeComponent(identity.jobID) else {
            throw LocalAudioImportFiles.Failure.invalidIdentity
        }
        let sourceDirectory = sourceRoot.appendingPathComponent(identity.jobID, isDirectory: true)
        let manifestURL = sourceDirectory.appendingPathComponent("manifest.json")
        try LocalAudioImportFiles.requireRegularFile(manifestURL, under: sourceRoot)
        var legacy = try JSONDecoder().decode(AudiobookManifest.self, from: Data(contentsOf: manifestURL))
        guard legacy.jobId == identity.jobID,
              Set(legacy.chapters.map(\.index)).count == legacy.chapters.count,
              Set(legacy.chapters.map(\.mp3FileName)).count == legacy.chapters.count else {
            throw LocalAudioImportFiles.Failure.invalidIdentity
        }
        var report = LegacyRetirementReport()
        var cancelled = false
        for chapter in legacy.chapters {
            // Stop between chapters, but still record what was already removed.
            if Task.isCancelled { cancelled = true; break }
            guard let canonicalIndex = identity.canonicalIndices[chapter.index] else { continue }
            do {
                report.chapters[chapter.index] = try retireLegacyChapter(
                    chapter, canonicalIndex: canonicalIndex, bookID: identity.bookID,
                    sourceRoot: sourceRoot, sourceDirectory: sourceDirectory,
                    converted: convertedFiles.map { $0[chapter.index] })
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                report.chapters[chapter.index] = .failed(error.localizedDescription)
            }
        }
        let retired = Set(report.chapters.filter { $0.value == .retired }.keys)
        if !retired.isEmpty {
            legacy.chapters.removeAll { retired.contains($0.index) }
            legacy.totalBytes = legacy.chapters.reduce(0) { $0 + $1.mp3Bytes }
            if legacy.chapters.isEmpty {
                try files.fileManager.removeItem(at: manifestURL)
                // Bookkeeping the app once wrote next to the manifest; nothing reads it.
                try? files.fileManager.removeItem(at: sourceDirectory.appendingPathComponent("last_access"))
                removeIfEmpty(sourceDirectory.appendingPathComponent("chapters", isDirectory: true))
                removeIfEmpty(sourceDirectory)
            } else {
                try JSONEncoder().encode(legacy).write(to: manifestURL, options: .atomic)
            }
        }
        report.remaining = legacy.chapters.count
        if cancelled { throw CancellationError() }
        return report
    }

    /// `converted` is nil for the store's own audio, `.some(nil)` when the job
    /// has no file for this chapter.
    private func retireLegacyChapter(
        _ chapter: AudiobookManifest.ChapterEntry, canonicalIndex: Int, bookID: String,
        sourceRoot: URL, sourceDirectory: URL, converted: URL??
    ) throws -> LegacyRetirementOutcome {
        guard LocalAudioImportFiles.isComponent(chapter.mp3FileName) else {
            throw LocalAudioImportFiles.Failure.invalidIdentity
        }
        let relativePath = files.relativePath(for: canonicalIndex)
        guard let artifact = try validatedManifest(bookID: bookID)?.chapters
            .first(where: { $0.index == canonicalIndex }),
              artifact.state == .available, artifact.relativePath == relativePath else { return .notImported }
        let kept = files.bookDirectory(bookID: bookID).appendingPathComponent(relativePath)
        try LocalAudioImportFiles.requireRegularFile(kept, under: files.root)
        let keptBytes = try LocalAudioImportFiles.fingerprint(kept)
        guard keptBytes.byteCount > 0, keptBytes.byteCount == artifact.byteCount else { return .notImported }

        let source = sourceDirectory.appendingPathComponent("chapters").appendingPathComponent(chapter.mp3FileName)
        let sourceExists = files.fileManager.fileExists(atPath: source.path)
        if sourceExists {
            try LocalAudioImportFiles.requireRegularFile(source, under: sourceRoot)
            guard try LocalAudioImportFiles.fingerprint(source) == keptBytes else { return .notImported }
            if let converted {
                guard let converted, try isProvenPlayback(converted, identicalTo: keptBytes) else {
                    return .playbackUnproven
                }
            }
        } else {
            // An earlier run removed the file and stopped before updating the manifest.
            guard keptBytes.byteCount == chapter.mp3Bytes else { return .notImported }
        }
        if artifact.retention != .downloaded {
            try promote(bookID: bookID, chapterIndex: canonicalIndex)
        }
        if sourceExists { try files.fileManager.removeItem(at: source) }
        return .retired
    }

    private func isProvenPlayback(_ url: URL, identicalTo kept: LocalAudioImportFiles.Fingerprint) throws -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        if try LocalAudioImportFiles.fingerprint(url) == kept { return true }
        do {
            try LocalAudioImportFiles.validateAudio(url)
            return true
        } catch LocalAudioImportFiles.Failure.invalidAudio {
            return false
        }
    }

    private func removeIfEmpty(_ directory: URL) {
        guard (try? files.fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true else { return }
        try? files.fileManager.removeItem(at: directory)
    }
}
