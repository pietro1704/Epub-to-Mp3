import Foundation
import os.log

private let cacheLog = Logger(subsystem: "epub2mp3", category: "ChapterCacheManager")

/// Tracks per-chapter audio cache status and drives background prefetch /
/// download-all for the embedded TTS path.
///
/// Each book's chapters are cached as `Caches/epub2mp3-tts/{bookId}/chapter_{index}.mp3`.
/// This manager observes which chapters are cached and provides:
/// 1. A `status(for:)` query returning `.cached`, `.generating`, or `.notStarted`.
/// 2. A `prefetchNext(_:from:)` call that synthesises the next N chapters.
/// 3. A `downloadAll()` call that synthesises all remaining chapters.
@MainActor
final class ChapterCacheManager: ObservableObject {

    static let clearAllNotification = Notification.Name("epub2mp3.clearAllChapterCaches")

    enum ChapterStatus: Equatable {
        case cached
        case generating
        case notStarted
    }

    /// Set of chapter indices currently being synthesised.
    @Published private(set) var generatingIndices: Set<Int> = []
    /// Set of chapter indices that have a cached MP3 on disk.
    @Published private(set) var cachedIndices: Set<Int> = []

    private let bookId: String
    private let cacheRoot: URL
    private let chapters: [EbookFulltext.Chapter]
    private let voice: String

    /// Active prefetch/download tasks keyed by chapter index.
    private var activeTasks: [Int: Task<Void, Never>] = [:]
    private var clearObserver: NSObjectProtocol?

    init(bookId: String, chapters: [EbookFulltext.Chapter], voice: String) {
        self.bookId = bookId
        self.chapters = chapters
        self.voice = voice
        let root = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epub2mp3-tts/\(bookId)", isDirectory: true)
        self.cacheRoot = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clearObserver = NotificationCenter.default.addObserver(
            forName: Self.clearAllNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearAll()
        }
        refreshCachedIndices()
    }

    deinit {
        if let clearObserver {
            NotificationCenter.default.removeObserver(clearObserver)
        }
    }

    /// Returns the current status of a chapter by index.
    func status(for index: Int) -> ChapterStatus {
        if cachedIndices.contains(index) { return .cached }
        if generatingIndices.contains(index) { return .generating }
        return .notStarted
    }

    /// Refresh which chapters are cached on disk.
    func refreshCachedIndices() {
        var cached = Set<Int>()
        for chapter in chapters {
            let idx = chapter.zeroBasedEpubIndex
            let file = cacheRoot.appendingPathComponent("chapter_\(idx).mp3")
            if FileManager.default.fileExists(atPath: file.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int64, size > 100 {
                cached.insert(idx)
            }
        }
        cachedIndices = cached
    }

    /// Prefetch the next `count` chapters after `currentIndex` that are not cached.
    func prefetchNext(_ count: Int = 2, from currentIndex: Int) {
        let uncached = chapters
            .map(\.zeroBasedEpubIndex)
            .filter { $0 > currentIndex && !cachedIndices.contains($0) && !generatingIndices.contains($0) }
            .sorted()
            .prefix(count)

        for idx in uncached {
            synthesizeChapter(at: idx)
        }
    }

    /// Synthesise all chapters that are not yet cached.
    func downloadAll() {
        let uncached = chapters
            .map(\.zeroBasedEpubIndex)
            .filter { !cachedIndices.contains($0) && !generatingIndices.contains($0) }
            .sorted()

        for idx in uncached {
            synthesizeChapter(at: idx)
        }
    }

    /// Cancel all active synthesis tasks.
    func cancelAll() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        generatingIndices.removeAll()
    }

    /// Cancel active synthesis and remove every cached chapter for this book.
    func clearAll() {
        cancelAll()
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        cachedIndices.removeAll()
    }

    // MARK: - Private

    private func synthesizeChapter(at arrayIndex: Int) {
        guard activeTasks[arrayIndex] == nil else { return }

        let chapter = chapters.first(where: { $0.zeroBasedEpubIndex == arrayIndex })
        guard let chapter else { return }

        let text = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 10 else { return }

        generatingIndices.insert(arrayIndex)

        let task = Task { [weak self] in
            guard let self else { return }
            let cacheFile = self.cacheRoot.appendingPathComponent("chapter_\(arrayIndex).mp3")

            // Double-check cache (might have been created by the main bootstrap).
            if FileManager.default.fileExists(atPath: cacheFile.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
               let size = attrs[.size] as? Int64, size > 100 {
                await MainActor.run {
                    self.cachedIndices.insert(arrayIndex)
                    self.generatingIndices.remove(arrayIndex)
                    self.activeTasks.removeValue(forKey: arrayIndex)
                }
                return
            }

            do {
                let normalized = EbookFulltext.Chapter.collapseHardWraps(text)
                let audio = try await Self.synthesizeDirectEdgeRaw(
                    text: normalized, voice: self.voice, chapterIndex: arrayIndex
                )
                try? FileManager.default.createDirectory(at: self.cacheRoot, withIntermediateDirectories: true)
                try audio.write(to: cacheFile)
                cacheLog.debug("[Prefetch] chapter \(arrayIndex) cached (\(audio.count) bytes)")
                await MainActor.run {
                    self.cachedIndices.insert(arrayIndex)
                    self.generatingIndices.remove(arrayIndex)
                    self.activeTasks.removeValue(forKey: arrayIndex)
                }
            } catch {
                cacheLog.error("[Prefetch] chapter \(arrayIndex) failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.generatingIndices.remove(arrayIndex)
                    self.activeTasks.removeValue(forKey: arrayIndex)
                }
            }
        }
        activeTasks[arrayIndex] = task
    }

    /// Synthesize via direct Edge WebSocket — same logic as BookOpenView.
    private nonisolated static func synthesizeDirectEdgeRaw(
        text: String, voice: String, chapterIndex: Int
    ) async throws -> Data {
        let sentences = splitForTTS(text, chapterIndex: chapterIndex)
        guard !sentences.isEmpty else { throw PythonBridgeError.emptyResult }

        var totalAudio = Data()
        for (segIdx, sentence) in sentences.enumerated() {
            let bridge = EdgeTTSBridge()
            let timeout = max(15.0, Double(sentence.text.count) / 100.0)
            let mp3 = try await withTimeout(seconds: timeout, label: "Edge prefetch \(segIdx)") {
                try await bridge.synthesize(text: sentence.text, voice: voice)
            }
            totalAudio.append(mp3)
        }
        guard !totalAudio.isEmpty else { throw PythonBridgeError.emptyResult }
        return totalAudio
    }

    private nonisolated static func splitForTTS(_ text: String, chapterIndex: Int) -> [SentenceSpan] {
        let chapter = EbookFulltext.Chapter(
            index: chapterIndex, name: nil, text: text,
            html: nil, css: nil, charCount: text.count, segments: nil
        )
        let raw = chapter.splitSentences()
        var batched: [SentenceSpan] = []
        var pendingText = ""
        var pendingId = ""
        var pendingStart = 0
        for span in raw {
            if pendingText.isEmpty {
                pendingText = span.text
                pendingId = span.id
                pendingStart = span.startChar
            } else {
                pendingText += " " + span.text
            }
            if pendingText.count >= 40 {
                batched.append(SentenceSpan(
                    id: pendingId, text: pendingText,
                    startChar: pendingStart, endChar: span.endChar
                ))
                pendingText = ""
            }
        }
        if !pendingText.isEmpty {
            let endChar = raw.last?.endChar ?? text.count
            batched.append(SentenceSpan(
                id: pendingId, text: pendingText,
                startChar: pendingStart, endChar: endChar
            ))
        }
        return batched
    }
}
