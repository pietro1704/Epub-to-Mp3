import XCTest
@testable import EpubToMp3

final class FailingImportCopyFileManager: FileManager, @unchecked Sendable {
    var failReplacement = false

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if failReplacement {
            try super.copyItem(at: srcURL, to: dstURL)
            return
        }
        try Data("Partial copy".utf8).write(to: dstURL)
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    }

    override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL,
                             backupItemName: String?, options: ItemReplacementOptions,
                             resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    }
}

final class MutatingImportCopyFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var nextCopyContents: Data?

    func mutateNextCopy(to contents: Data) {
        lock.lock(); defer { lock.unlock() }
        nextCopyContents = contents
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        lock.lock()
        let replacement = nextCopyContents
        nextCopyContents = nil
        lock.unlock()
        if let replacement { try replacement.write(to: dstURL, options: .atomic) }
    }
}

/// Only the test manager crosses threads; mutable observations are lock-protected.
final class ObservedImportFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var pause: XCTestExpectation?
    private var failCopy = false
    private var observations: [Bool] = []

    func pauseNextCopy(until expectation: XCTestExpectation) {
        lock.lock(); defer { lock.unlock() }
        pause = expectation
    }

    func releaseCopy() { release.signal() }

    func failNextCopy() {
        lock.lock(); defer { lock.unlock() }
        failCopy = true
    }

    var copyThreads: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return observations
    }

    override func copyItem(at source: URL, to destination: URL) throws {
        lock.lock()
        observations.append(Thread.isMainThread)
        let waiting = pause
        pause = nil
        let failing = failCopy
        failCopy = false
        lock.unlock()
        if let waiting {
            waiting.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else {
                throw NSError(domain: "LibraryImportTests", code: 1)
            }
        }
        if failing {
            try Data("Partial copy".utf8).write(to: destination)
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        }
        try super.copyItem(at: source, to: destination)
    }
}

final class ObservedLibraryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var writeThreads: [Bool] = []
    var libraryWrites: Int {
        lock.lock(); defer { lock.unlock() }
        return writes
    }
    var libraryWriteThreads: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return writeThreads
    }
    override func set(_ value: Any?, forKey key: String) {
        if key == "library.books.v1" {
            lock.lock(); writes += 1; writeThreads.append(Thread.isMainThread); lock.unlock()
        }
        super.set(value, forKey: key)
    }
}

final class LibraryEncoderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var waiting: XCTestExpectation?
    private var failNext = false
    private var observations: [(Bool, String?)] = []

    func pauseNextEncoding(until expectation: XCTestExpectation) {
        lock.lock(); defer { lock.unlock() }
        waiting = expectation
    }
    func releaseEncoding() { resume.signal() }
    func failNextEncoding() {
        lock.lock(); defer { lock.unlock() }
        failNext = true
    }
    var encodedSnapshots: [(Bool, String?)] {
        lock.lock(); defer { lock.unlock() }
        return observations
    }
    func encode(_ books: [BookEntity]) throws -> Data {
        lock.lock()
        observations.append((Thread.isMainThread, books.first?.title))
        let entered = waiting
        waiting = nil
        let shouldFail = failNext
        failNext = false
        lock.unlock()
        if let entered {
            entered.fulfill()
            guard resume.wait(timeout: .now() + 5) == .success else {
                throw NSError(domain: "LibraryPersistenceTests", code: 1)
            }
        }
        if shouldFail {
            throw NSError(domain: "LibraryPersistenceTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Index encoding failed"])
        }
        return try JSONEncoder().encode(books)
    }
}

final class LibraryStoreTests: XCTestCase {










    #if os(macOS)
    #endif

    func ephemeralStore() -> (LibraryStore, UserDefaults, String) {
        let suite = "library.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
        addTeardownBlock {
            try? store.flushPersistenceSync()
            defaults.removePersistentDomain(forName: suite)
        }
        return (store, defaults, suite)
    }




















    #if os(macOS)
    #endif
}
