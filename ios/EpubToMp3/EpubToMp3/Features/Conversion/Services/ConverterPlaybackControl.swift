import Foundation

final class ConverterPlaybackControl: @unchecked Sendable {
    let rawHandle: UnsafeMutableRawPointer
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    private var readerChapterMap: ReaderConversionChapterMap?
    private var requestedWindow: (chapter: Int, ahead: Int)?
    private var requestedPriority: Int?
    private var requestedTextRatio: Double = 0
    private var listeningEnabled = false
    private let listeningPosition: ConverterJobControlJSON?
    private let playbackFeedback: ConverterJobControlJSON?
    private let listeningGeneration: ConverterJobControlGeneration?
    private var currentListeningGeneration: UInt64 = 0
    var playbackTask: Task<Void, Never>?
    var isCancellationRequested: Bool {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        return cancellationRequested
    }
    private let free: ConverterJobControlFree
    private let cancelJob: ConverterJobControlCancel
    private let prioritizeChapter: ConverterJobControlPrioritize
    private let setPlaybackWindow: ConverterJobControlWindow
    private let chapterIsInPlaybackWindow: ConverterJobControlWindowContains

    init(
        rawHandle: UnsafeMutableRawPointer,
        free: @escaping ConverterJobControlFree,
        cancel: @escaping ConverterJobControlCancel,
        prioritize: @escaping ConverterJobControlPrioritize,
        setWindow: @escaping ConverterJobControlWindow,
        windowContains: @escaping ConverterJobControlWindowContains,
        listeningPosition: ConverterJobControlJSON? = nil,
        playbackFeedback: ConverterJobControlJSON? = nil,
        listeningGeneration: ConverterJobControlGeneration? = nil
    ) {
        self.rawHandle = rawHandle
        self.free = free
        cancelJob = cancel
        prioritizeChapter = prioritize
        setPlaybackWindow = setWindow
        chapterIsInPlaybackWindow = windowContains
        self.listeningPosition = listeningPosition
        self.playbackFeedback = playbackFeedback
        self.listeningGeneration = listeningGeneration
    }

    deinit { playbackTask?.cancel(); free(rawHandle) }
    func cancel() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
        playbackTask?.cancel()
        cancelJob(rawHandle)
    }
    @discardableResult func prioritize(chapterIndex: Int) -> Bool {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return false }
        requestedPriority = chapterIndex
        guard let position = corePosition(chapterIndex) else { return false }
        return prioritizeChapter(rawHandle, position)
    }
    func updatePlaybackWindow(currentChapter: Int, chaptersAhead: Int = 1) {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return }
        if let chapter = requestedWindow?.chapter, chapter != currentChapter { requestedTextRatio = 0 }
        requestedWindow = (currentChapter, chaptersAhead)
        guard let position = corePosition(currentChapter) else { return }
        setPlaybackWindow(rawHandle, position, chaptersAhead)
        sendListeningPosition(position, ratio: requestedTextRatio)
    }
    func contains(chapterIndex: Int) -> Bool {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return false }
        guard let position = corePosition(chapterIndex) else { return false }
        return chapterIsInPlaybackWindow(rawHandle, position)
    }

    func installReaderChapterMap(_ map: ReaderConversionChapterMap) {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return }
        readerChapterMap = map
        if let window = requestedWindow, let position = corePosition(window.chapter) {
            setPlaybackWindow(rawHandle, position, window.ahead)
            sendListeningPosition(position, ratio: requestedTextRatio)
        }
        if let priority = requestedPriority, let position = corePosition(priority) {
            _ = prioritizeChapter(rawHandle, position)
        }
    }

    private func corePosition(_ chapter: Int) -> Int? {
        guard let readerChapterMap else { return chapter }
        return try? readerChapterMap.corePosition(for: chapter)
    }

    func startFromPage(ratio: Double) {
        guard ratio.isFinite, (0...1).contains(ratio) else { return }
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return }
        listeningEnabled = true
        requestedTextRatio = ratio
        if let chapter = requestedWindow?.chapter, let position = corePosition(chapter) {
            sendListeningPosition(position, ratio: ratio)
        }
    }

    private func sendListeningPosition(_ position: Int, ratio: Double) {
        guard listeningEnabled, let listeningPosition else { return }
        let chars = readerChapterMap?.coreTextChars[position] ?? 0
        let offset = min(max(chars - 1, 0), Int((Double(chars) * ratio).rounded(.down)))
        guard let json = try? JSONSerialization.data(withJSONObject: ["version": 2, "chapter_index": position, "text_offset": offset]) else { return }
        if String(decoding: json, as: UTF8.self).withCString({ listeningPosition(rawHandle, $0) }) {
            currentListeningGeneration = listeningGeneration?(rawHandle) ?? 0
        }
    }

    func enableListening() {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return }
        listeningEnabled = true
        if let chapter = requestedWindow?.chapter, let position = corePosition(chapter) { sendListeningPosition(position, ratio: requestedTextRatio) }
    }

    func sendPlaybackFeedback(chapter: Int, remaining: Double, rate: Double) {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return }
        guard let playbackFeedback, let position = corePosition(chapter),
              let json = try? JSONSerialization.data(withJSONObject: ["version": 2, "generation": currentListeningGeneration, "chapter_index": position, "remaining_audio_seconds": remaining, "playback_rate": rate]) else { return }
        _ = String(decoding: json, as: UTF8.self).withCString { playbackFeedback(rawHandle, $0) }
    }
}
