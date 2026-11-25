import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AudiobookDownloadStorage {

    // MARK: Storage layout (nonisolated — no instance state)

    static let audiobooksFolderName = "Audiobooks"
    static let applicationSupportFolderName = "EpubToMp3"
    /// Test-only storage injection. Production never assigns this value;
    /// tests use it to keep fixtures out of Documents/Application Support.
    nonisolated(unsafe) static var rootOverrideForTesting: URL?

    static func audiobooksRoot() -> URL {
        let url = audiobooksRootLocation()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Where the root is, without creating it. Reads use this so that asking
    /// about kept audio never leaves an empty folder behind.
    static func audiobooksRootLocation() -> URL {
        if let override = rootOverrideForTesting { return override }
        let base: URL
        #if os(macOS)
        // App-owned audio must stay inside the sandbox. Reading the user's
        // Documents directory on every launch triggers a macOS privacy prompt
        // even though the user only selected a book once in the file picker.
        base = ApplicationSupportRoot.url().appendingPathComponent(applicationSupportFolderName, isDirectory: true)
        #else
        base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent(audiobooksFolderName, isDirectory: true)
    }

    /// The job's folder directly under the Audiobooks root, or nil when the id
    /// is not a safe single path component (see `LegacyJobDirectory`).
    static func jobDirectory(for jobId: String, operation: String = #function) -> URL? {
        LegacyJobDirectory.directory(for: jobId, under: audiobooksRootLocation(), operation: operation)
    }

    /// `chapters/` inside the job folder, refused when it is a symlink so
    /// chapter reads and removals cannot follow it outside the root.
    fileprivate static func chaptersDirectory(for jobId: String, operation: String) -> URL? {
        guard let directory = jobDirectory(for: jobId, operation: operation) else { return nil }
        return LegacyJobDirectory.directory(for: "chapters", under: directory, operation: operation)
    }

    static func audiobookFolder(for jobId: String) -> URL? {
        guard let url = chaptersDirectory(for: jobId, operation: #function) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func manifestURL(for jobId: String) -> URL? {
        jobDirectory(for: jobId)?.appendingPathComponent("manifest.json")
    }

    static func loadManifest(for jobId: String) -> AudiobookManifest? {
        guard let url = manifestURL(for: jobId), let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(AudiobookManifest.self, from: data),
              manifest.jobId == jobId else { return nil }
        return manifest
    }

    /// Chapter indices (same axis as `JobSnapshot.Chapter.index`) whose MP3
    /// is actually present on disk for `jobId`. The manifest records what
    /// finished downloading, but eviction or the OS can remove files without
    /// rewriting it — so every entry is re-verified against the filesystem.
    /// This is the source of truth for "downloaded" UI badges; a snapshot's
    /// `downloadUrl` only means the SERVER has the chapter.
    static func locallyDownloadedIndices(for jobId: String) -> Set<Int> {
        guard let manifest = loadManifest(for: jobId) else { return [] }
        // This is a read-only query. Do not call `audiobookFolder(for:)`
        // here because that helper creates missing directories, causing
        // filesystem work for every absent/evicted manifest lookup.
        guard let folder = chaptersDirectory(for: jobId, operation: #function) else { return [] }
        return Set(manifest.chapters.filter { keptAudio($0, in: folder) != nil }.map(\.index))
    }

    static func localAudioURL(jobId: String, chapterIndex: Int) -> URL? {
        guard let entry = loadManifest(for: jobId)?.chapters.first(where: { $0.index == chapterIndex }),
              let folder = chaptersDirectory(for: jobId, operation: #function) else { return nil }
        return keptAudio(entry, in: folder)
    }

    fileprivate static func keptAudio(_ entry: AudiobookManifest.ChapterEntry, in folder: URL) -> URL? {
        guard LegacyJobDirectory.isSafeComponent(entry.mp3FileName) else { return nil }
        let url = folder.appendingPathComponent(entry.mp3FileName)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else { return nil }
        return url
    }

    /// Reconstructs a player snapshot from already-downloaded remote audio.
    /// This keeps a remote-backed book usable after relaunch without asking
    /// the server for a job snapshot before the listener can press Play.
    static func localPlaybackSnapshot(jobId: String) -> JobSnapshot? {
        guard let manifest = loadManifest(for: jobId) else { return nil }
        let chapters = manifest.chapters.compactMap { entry -> JobSnapshot.Chapter? in
            guard let url = localAudioURL(jobId: jobId, chapterIndex: entry.index) else { return nil }
            return JobSnapshot.Chapter(
                index: entry.index,
                name: entry.title,
                status: "completed",
                downloadUrl: url.absoluteString,
                chars: nil,
                charsProcessed: nil,
                progressRatio: 1,
                durationSeconds: nil,
                startedAt: nil,
                completedAt: entry.downloadedAt.timeIntervalSince1970,
                textOffset: entry.textOffset
            )
        }
        guard !chapters.isEmpty else { return nil }
        let completed = manifest.completedAt != nil
        return JobSnapshot(
            jobId: jobId,
            state: completed ? "finished" : "partial",
            bookTitle: manifest.bookTitle,
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: "remote",
            voice: "remote",
            language: nil,
            progressPercent: completed ? 100 : 0,
            chaptersTotal: max(chapters.count, manifest.chapters.count),
            chaptersCompleted: chapters.count,
            chapterProgress: chapters,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: manifest.completedAt?.timeIntervalSince1970,
            chapterIndexBase: manifest.chapterIndexBase
        )
    }

    /// A converted chapter plays from its own file. Copies kept by the previous
    /// layout only add the chapters the conversion does not have.
    static func restoredPlaybackSnapshot(jobId: String, conversionSnapshot: JobSnapshot?) -> JobSnapshot? {
        let local = localPlaybackSnapshot(jobId: jobId)
        guard let conversion = conversionSnapshot, conversion.jobId == jobId else { return local }
        var chapters = conversion.playableChapters
        let converted = Set(chapters.map(\.index))
        chapters += (local?.playableChapters ?? []).filter { !converted.contains($0.index) }
        guard !chapters.isEmpty else { return local }
        chapters.sort { $0.index < $1.index }
        return JobSnapshot(jobId: conversion.jobId, state: conversion.state,
            bookTitle: conversion.bookTitle, bookAuthor: conversion.bookAuthor,
            coverUrl: conversion.coverUrl, coverMimeType: conversion.coverMimeType,
            engine: conversion.engine, voice: conversion.voice, language: conversion.language,
            progressPercent: conversion.progressPercent, chaptersTotal: conversion.chaptersTotal,
            chaptersCompleted: chapters.count, chapterProgress: chapters, outputs: conversion.outputs,
            logUrl: conversion.logUrl, error: conversion.error, lastActivityAt: conversion.lastActivityAt,
            chapterIndexBase: conversion.chapterIndexBase, sourceChaptersTotal: conversion.sourceChaptersTotal)
    }

    /// Remove exactly one job's folder. An unsafe id is a logged no-op, so a
    /// library removal still clears the book's other stores.
    static func deleteAudiobook(jobId: String) {
        guard let folder = jobDirectory(for: jobId),
              !DownloadedAudioFilesMirror.isMirrorFolder(folder) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    static func deleteChapter(jobId: String, chapterIndex: Int) {
        guard let directory = jobDirectory(for: jobId),
              !DownloadedAudioFilesMirror.isMirrorFolder(directory),
              var manifest = loadManifest(for: jobId),
              let entry = manifest.chapters.first(where: { $0.index == chapterIndex }) else { return }
        // The file name comes from the manifest on disk; it must stay inside chapters/.
        if LegacyJobDirectory.isSafeComponent(entry.mp3FileName),
           let chapters = chaptersDirectory(for: jobId, operation: #function) {
            let chapterURL = chapters.appendingPathComponent(entry.mp3FileName)
            try? FileManager.default.removeItem(at: chapterURL)
        }
        manifest.chapters.removeAll { $0.index == chapterIndex }
        manifest.totalBytes = max(0, manifest.totalBytes - entry.mp3Bytes)
        manifest.completedAt = nil
        try? JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

}

extension LocalAudioArtifactStore {
    /// Publishes a job-scoped chapter with its own index. The same actor
    /// serializes publication and any migration that later proves the mapping.
    func retainJobDownload(from source: URL, snapshot: JobSnapshot, chapter: JobSnapshot.Chapter) throws -> Int64 {
        try Task.checkCancellation()
        let jobID = snapshot.jobId
        let root = AudiobookDownloadStorage.audiobooksRootLocation().standardizedFileURL.resolvingSymlinksInPath()
        guard chapter.index >= 0,
              let directory = AudiobookDownloadStorage.jobDirectory(for: jobID),
              !DownloadedAudioFilesMirror.isMirrorFolder(directory),
              let folder = AudiobookDownloadStorage.chaptersDirectory(for: jobID, operation: #function) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try LocalAudioImportFiles.checkPath(manifestURL, under: root)
        let fileManager = FileManager.default
        var manifest = AudiobookManifest(
            jobId: jobID, bookTitle: snapshot.bookTitle ?? jobID, chapters: [], totalBytes: 0, completedAt: nil)
        if fileManager.fileExists(atPath: manifestURL.path) {
            try LocalAudioImportFiles.requireRegularFile(manifestURL, under: root)
            manifest = try JSONDecoder().decode(AudiobookManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.jobId == jobID,
                  Set(manifest.chapters.map(\.index)).count == manifest.chapters.count,
                  Set(manifest.chapters.map(\.mp3FileName)).count == manifest.chapters.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let savedBase = manifest.chapterIndexBase, let incomingBase = snapshot.chapterIndexBase,
               savedBase != incomingBase {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else { throw StoreError.invalidAudioFile(source) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".download-\(UUID().uuidString).mp3")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        guard try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else {
            throw StoreError.invalidAudioFile(source)
        }
        try Task.checkCancellation()
        let title = DownloadedAudioFilesMirror.component(chapter.displayTitle, fallback: "Chapter")
        let stem = "\(chapter.index) - \(title)"
        var destination = folder.appendingPathComponent("\(stem).mp3")
        if fileManager.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(stem) (\(UUID().uuidString)).mp3")
        }
        // The new file gets its own name, so a failed manifest write cannot
        // replace a different file that the listener already has.
        try fileManager.moveItem(at: staging, to: destination)
        do {
            manifest.chapters.removeAll { $0.index == chapter.index }
            manifest.chapters.append(.init(index: chapter.index, title: chapter.displayTitle,
                mp3FileName: destination.lastPathComponent, mp3Bytes: Int64(size), downloadedAt: Date(),
                textOffset: chapter.textOffset))
            manifest.chapters.sort { $0.index < $1.index }
            var keptIndices: Set<Int> = []
            manifest.totalBytes = 0
            for entry in manifest.chapters {
                guard let file = AudiobookDownloadStorage.keptAudio(entry, in: folder),
                      let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
                keptIndices.insert(entry.index)
                manifest.totalBytes += Int64(fileSize)
            }
            let complete = Set(snapshot.playableChapters.map(\.index)).isSubset(of: keptIndices)
            manifest.completedAt = complete ? Date() : nil
            if let indexBase = snapshot.chapterIndexBase { manifest.chapterIndexBase = indexBase }
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return Int64(size)
    }
}
