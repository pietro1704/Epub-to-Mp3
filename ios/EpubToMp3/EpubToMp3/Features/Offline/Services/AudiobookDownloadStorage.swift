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
        if let override = rootOverrideForTesting {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
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
        let url = base.appendingPathComponent(audiobooksFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func audiobookFolder(for jobId: String) -> URL {
        let url = audiobooksRoot().appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("chapters", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func manifestURL(for jobId: String) -> URL {
        audiobooksRoot().appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("manifest.json")
    }

    static func loadManifest(for jobId: String) -> AudiobookManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: jobId)) else { return nil }
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
        let folder = audiobooksRoot()
            .appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("chapters", isDirectory: true)
        let fm = FileManager.default
        return Set(
            manifest.chapters
                .filter { fm.fileExists(atPath: folder.appendingPathComponent($0.mp3FileName).path) }
                .map(\.index)
        )
    }

    static func localAudioURL(jobId: String, chapterIndex: Int) -> URL? {
        guard let entry = loadManifest(for: jobId)?.chapters.first(where: { $0.index == chapterIndex }) else { return nil }
        let url = audiobookFolder(for: jobId).appendingPathComponent(entry.mp3FileName)
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
                    startedAt: source.startedAt, completedAt: source.completedAt)
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
            logUrl: conversion.logUrl, error: conversion.error, lastActivityAt: conversion.lastActivityAt)
    }

    static func reusableDownloadedEntry(
        chapterIndex: Int,
        manifestEntry: AudiobookManifest.ChapterEntry?,
        fileExists: Bool
    ) -> AudiobookManifest.ChapterEntry? {
        guard let manifestEntry,
              manifestEntry.index == chapterIndex,
              manifestEntry.mp3Bytes > 0,
              fileExists else { return nil }
        return manifestEntry
    }

    static func mergeManifests(_ old: AudiobookManifest?, _ incoming: AudiobookManifest) -> AudiobookManifest {
        guard let old else { return incoming }
        var byIndex = Dictionary(uniqueKeysWithValues: old.chapters.map { ($0.index, $0) })
        for entry in incoming.chapters { byIndex[entry.index] = entry }
        let chapters = byIndex.values.sorted { $0.index < $1.index }
        return AudiobookManifest(jobId: incoming.jobId, bookTitle: incoming.bookTitle,
                                 chapters: chapters,
                                 totalBytes: chapters.reduce(0) { $0 + $1.mp3Bytes },
                                 completedAt: incoming.completedAt ?? old.completedAt)
    }

    static func isManifestComplete(_ manifest: AudiobookManifest, expectedChapterIndices: [Int]) -> Bool {
        let expected = Set(expectedChapterIndices)
        guard Set(manifest.chapters.map(\.index)) == expected else { return false }
        let folder = audiobookFolder(for: manifest.jobId)
        let fileManager = FileManager.default
        return manifest.chapters.allSatisfy { entry in
            let url = folder.appendingPathComponent(entry.mp3FileName)
            guard fileManager.fileExists(atPath: url.path),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int64 else {
                return false
            }
            return size > 0
        }
    }

    static func saveManifest(_ manifest: AudiobookManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(for: manifest.jobId), options: .atomic)
    }
    static func deleteAudiobook(jobId: String) {
        let folder = audiobooksRoot().appendingPathComponent(jobId, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    static func deleteChapter(jobId: String, chapterIndex: Int) {
        guard var manifest = loadManifest(for: jobId),
              let entry = manifest.chapters.first(where: { $0.index == chapterIndex }) else { return }
        let chapterURL = audiobooksRoot()
            .appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("chapters", isDirectory: true)
            .appendingPathComponent(entry.mp3FileName)
        try? FileManager.default.removeItem(at: chapterURL)
        manifest.chapters.removeAll { $0.index == chapterIndex }
        manifest.totalBytes = max(0, manifest.totalBytes - entry.mp3Bytes)
        try? JSONEncoder().encode(manifest).write(to: manifestURL(for: jobId), options: .atomic)
    }

}
