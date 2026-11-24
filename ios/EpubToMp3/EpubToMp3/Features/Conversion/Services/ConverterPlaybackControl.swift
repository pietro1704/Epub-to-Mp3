import Foundation

final class ConverterPlaybackControl: @unchecked Sendable {
    let rawHandle: UnsafeMutableRawPointer
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    private var readerChapterMap: ReaderConversionChapterMap?
    private var requestedWindow: (chapter: Int, ahead: Int)?
    private var requestedPriority: Int?
    private enum RequestedTextPosition {
        case ratio(Double)
        case sourceScalarOffset(Int)
    }

    private var requestedTextPosition: RequestedTextPosition = .ratio(0)
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
    private let chapterIsPreempted: ConverterJobControlWindowContains?

    init(
        rawHandle: UnsafeMutableRawPointer,
        free: @escaping ConverterJobControlFree,
        cancel: @escaping ConverterJobControlCancel,
        prioritize: @escaping ConverterJobControlPrioritize,
        setWindow: @escaping ConverterJobControlWindow,
        windowContains: @escaping ConverterJobControlWindowContains,
        chapterIsPreempted: ConverterJobControlWindowContains? = nil,
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
        self.chapterIsPreempted = chapterIsPreempted
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
        if let chapter = requestedWindow?.chapter, chapter != currentChapter { requestedTextPosition = .ratio(0) }
        requestedWindow = (currentChapter, chaptersAhead)
        guard let position = corePosition(currentChapter) else { return }
        setPlaybackWindow(rawHandle, position, chaptersAhead)
        sendListeningPosition(position)
    }
    func contains(chapterIndex: Int) -> Bool {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return false }
        guard let position = corePosition(chapterIndex) else { return false }
        return chapterIsInPlaybackWindow(rawHandle, position)
    }

    /// True while the core has preempted `chapterIndex` for a listener seek: its in-flight chunks must be dropped
    /// (its finished segments stay cached and it resumes after the target).
    func isPreempted(chapterIndex: Int) -> Bool {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested, let chapterIsPreempted, let position = corePosition(chapterIndex) else { return false }
        return chapterIsPreempted(rawHandle, position)
    }

    /// Whether a delivered chunk or chapter event of `chapterIndex` is still wanted by the listener.
    func acceptsChunks(forChapter chapterIndex: Int) -> Bool {
        !isCancellationRequested && !isPreempted(chapterIndex: chapterIndex)
    }

    func installReaderChapterMap(_ map: ReaderConversionChapterMap) {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return }
        readerChapterMap = map
        if let window = requestedWindow, let position = corePosition(window.chapter) {
            setPlaybackWindow(rawHandle, position, window.ahead)
            sendListeningPosition(position)
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
        startListening(at: .ratio(ratio))
    }

    func startFromPage(sourceScalarOffset: Int) {
        guard sourceScalarOffset >= 0 else { return }
        startListening(at: .sourceScalarOffset(sourceScalarOffset))
    }

    private func startListening(at textPosition: RequestedTextPosition) {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return }
        listeningEnabled = true
        requestedTextPosition = textPosition
        if let chapter = requestedWindow?.chapter, let position = corePosition(chapter) {
            sendListeningPosition(position)
        }
    }

    private func sendListeningPosition(_ position: Int) {
        guard listeningEnabled, let listeningPosition else { return }
        let offset: Int
        switch requestedTextPosition {
        case .ratio(let ratio):
            let chars = readerChapterMap?.coreTextChars[position] ?? 0
            offset = min(max(chars - 1, 0), Int((Double(chars) * ratio).rounded(.down)))
        case .sourceScalarOffset(let sourceScalarOffset):
            offset = sourceScalarOffset
        }
        guard let json = try? JSONSerialization.data(withJSONObject: ["version": 2, "chapter_index": position, "text_offset": offset]) else { return }
        if String(decoding: json, as: UTF8.self).withCString({ listeningPosition(rawHandle, $0) }) {
            currentListeningGeneration = listeningGeneration?(rawHandle) ?? 0
        }
    }

    func enableListening() {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return }
        listeningEnabled = true
        if let chapter = requestedWindow?.chapter, let position = corePosition(chapter) { sendListeningPosition(position) }
    }

    func sendPlaybackFeedback(chapter: Int, remaining: Double, rate: Double) {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        guard !cancellationRequested else { return }
        guard let playbackFeedback, let position = corePosition(chapter),
              let json = try? JSONSerialization.data(withJSONObject: ["version": 2, "generation": currentListeningGeneration, "chapter_index": position, "remaining_audio_seconds": remaining, "playback_rate": rate]) else { return }
        _ = String(decoding: json, as: UTF8.self).withCString { playbackFeedback(rawHandle, $0) }
    }
}
