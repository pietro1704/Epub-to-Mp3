import Foundation

final class ConverterPlaybackControl: @unchecked Sendable {
    let rawHandle: UnsafeMutableRawPointer
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
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
        windowContains: @escaping ConverterJobControlWindowContains
    ) {
        self.rawHandle = rawHandle
        self.free = free
        cancelJob = cancel
        prioritizeChapter = prioritize
        setPlaybackWindow = setWindow
        chapterIsInPlaybackWindow = windowContains
    }

    deinit { free(rawHandle) }
    func cancel() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
        cancelJob(rawHandle)
    }
    @discardableResult func prioritize(chapterIndex: Int) -> Bool {
        prioritizeChapter(rawHandle, chapterIndex)
    }
    func updatePlaybackWindow(currentChapter: Int, chaptersAhead: Int = 1) {
        setPlaybackWindow(rawHandle, currentChapter, chaptersAhead)
    }
    func contains(chapterIndex: Int) -> Bool {
        chapterIsInPlaybackWindow(rawHandle, chapterIndex)
    }
}
