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
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        base = support.appendingPathComponent(applicationSupportFolderName, isDirectory: true)
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
    private static func chaptersDirectory(for jobId: String, operation: String) -> URL? {
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
        guard let url = manifestURL(for: jobId), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AudiobookManifest.self, from: data)
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
        let fm = FileManager.default
        return Set(
            manifest.chapters
                .filter { fm.fileExists(atPath: folder.appendingPathComponent($0.mp3FileName).path) }
                .map(\.index)
        )
    }

    static func localAudioURL(jobId: String, chapterIndex: Int) -> URL? {
        guard let entry = loadManifest(for: jobId)?.chapters.first(where: { $0.index == chapterIndex }),
              let url = audiobookFolder(for: jobId)?.appendingPathComponent(entry.mp3FileName) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path),
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
              size > 0 else { return nil }
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
                completedAt: entry.downloadedAt.timeIntervalSince1970
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
            lastActivityAt: manifest.completedAt?.timeIntervalSince1970
        )
    }

    /// Retained downloads override matching Rust files without hiding other converted chapters.
    static func restoredPlaybackSnapshot(jobId: String, conversionSnapshot: JobSnapshot?) -> JobSnapshot? {
        let local = localPlaybackSnapshot(jobId: jobId)
        guard let conversion = conversionSnapshot, conversion.jobId == jobId else { return local }
        var chapters = conversion.playableChapters
        for retained in local?.playableChapters ?? [] {
            if let offset = chapters.firstIndex(where: { $0.index == retained.index }) {
                let source = chapters[offset]
                chapters[offset] = .init(index: source.index, name: source.name, status: source.status,
                    downloadUrl: retained.downloadUrl, chars: source.chars, charsProcessed: source.charsProcessed,
                    progressRatio: source.progressRatio, durationSeconds: source.durationSeconds,
                    startedAt: source.startedAt, completedAt: source.completedAt, textOffset: source.textOffset)
            } else {
                chapters.append(retained)
            }
        }
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
        guard let folder = jobDirectory(for: jobId) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    static func deleteChapter(jobId: String, chapterIndex: Int) {
        guard let directory = jobDirectory(for: jobId),
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
        try? JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

}
