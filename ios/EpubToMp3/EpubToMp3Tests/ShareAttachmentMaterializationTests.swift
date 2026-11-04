#if os(iOS)
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import EpubToMp3

private final class ShareInboxFileManager: FileManager, @unchecked Sendable {
    private let container: URL
    init(container: URL) { self.container = container; super.init() }
    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? { container }
}

private final class PartialShareCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at source: URL, to destination: URL) throws {
        try Data("Partial owned copy".utf8).write(to: destination)
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

private final class HeldShareAttachment: @unchecked Sendable {
    private let lock = NSLock()
    private let source: URL
    private let entered: XCTestExpectation
    private var completion: NSItemProviderCompletionHandler?
    private var released = false

    init(source: URL, entered: XCTestExpectation) { self.source = source; self.entered = entered }

    func provider(typeIdentifier: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: typeIdentifier) { [self] callback, _, _ in capture(callback) }
        return provider
    }

    private func capture(_ callback: NSItemProviderCompletionHandler?) {
        lock.lock()
        let alreadyReleased = released
        if !alreadyReleased { completion = callback }
        lock.unlock()
        entered.fulfill()
        if alreadyReleased { callback?(source as NSURL, nil) }
    }

    func release() {
        lock.lock()
        released = true
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(source as NSURL, nil)
    }
}

@MainActor
final class ShareAttachmentMaterializationTests: XCTestCase {
    func testURLAttachmentsUseAcceptedTypeAndReachDurableLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let cases = [
            ("Novel", UTType.epub.identifier, "epub"),
            ("Novel.bin", UTType.epub.identifier, "epub"),
            ("Legacy", "org.idpf.epub-container", "epub"),
            ("Books.bin", "com.apple.ibooks.epub", "epub"),
            ("Report", UTType.pdf.identifier, "pdf"),
            ("Report.bin", UTType.pdf.identifier, "pdf"),
            ("Report.epub", UTType.pdf.identifier, "pdf"),
            ("Novel.pdf", UTType.epub.identifier, "epub"),
            ("Original.PDF", UTType.pdf.identifier, "pdf")
        ]
        for (filename, typeID, ext) in cases {
            let source = try fixture.makeSource(filename: filename, fileExtension: ext)
            let provider = NSItemProvider(item: source as NSURL, typeIdentifier: typeID)

            let materialized = try await ShareViewController.loadFileURL(
                from: provider, typeIdentifier: typeID, temporaryDirectory: fixture.temporaryDirectory)

            XCTAssertTrue(materialized.deletingPathExtension().lastPathComponent.hasSuffix(
                source.deletingPathExtension().lastPathComponent))
            try await fixture.assertImport(materialized: materialized, source: source, fileExtension: ext)
        }
    }

    func testDataAttachmentsKeepAcceptedTypeAndBytesThroughInboxImport() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for (index, typeID) in ShareViewController.acceptedTypeIdentifiers.enumerated() {
            let ext = typeID == UTType.pdf.identifier ? "pdf" : "epub"
            let source = try fixture.makeSource(filename: "Data-\(index).\(ext)", fileExtension: ext)
            let bytes = try Data(contentsOf: source)
            let provider = NSItemProvider(item: bytes as NSData, typeIdentifier: typeID)
            provider.suggestedName = "Misleading.bin"

            let materialized = try await ShareViewController.loadFileURL(
                from: provider, typeIdentifier: typeID, temporaryDirectory: fixture.temporaryDirectory)

            try await fixture.assertImport(materialized: materialized, source: source, fileExtension: ext)
        }
    }

    func testConcurrentLoadsOfSameFilenameKeepDistinctOwnedCopies() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource(filename: "Shared.bin", fileExtension: "epub")
        let firstProvider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.epub.identifier)
        let secondProvider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.epub.identifier)
        async let first = ShareViewController.loadFileURL(from: firstProvider, typeIdentifier: UTType.epub.identifier,
                                                        temporaryDirectory: fixture.temporaryDirectory)
        async let second = ShareViewController.loadFileURL(from: secondProvider, typeIdentifier: UTType.epub.identifier,
                                                         temporaryDirectory: fixture.temporaryDirectory)

        let (firstCopy, secondCopy) = try await (first, second)

        XCTAssertNotEqual(firstCopy, secondCopy)
        XCTAssertEqual(firstCopy.pathExtension, "epub")
        XCTAssertEqual(secondCopy.pathExtension, "epub")
        XCTAssertEqual(try Data(contentsOf: firstCopy), try Data(contentsOf: source))
        XCTAssertEqual(try Data(contentsOf: secondCopy), try Data(contentsOf: source))
        try await fixture.assertImport(materialized: firstCopy, source: source, fileExtension: "epub")
        try await fixture.assertImport(materialized: secondCopy, source: source, fileExtension: "epub")
        XCTAssertEqual(fixture.library.books.count, 1, "Repeated content keeps its original library identity")
    }

    func testFailedCopyRemovesOnlyPartialOwnedDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource(filename: "Failed.bin", fileExtension: "epub")
        let provider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.epub.identifier)

        let captured = await captureFailure(from: provider, typeID: UTType.epub.identifier, fixture: fixture,
                                            fileManager: PartialShareCopyFileManager())
        let error = try XCTUnwrap(captured) as NSError

        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error.code, CocoaError.fileWriteOutOfSpace.rawValue)
        try fixture.assertNoPublishedOrTemporaryImport(source: source)
    }

    func testProviderFailureDoesNotPublishAFileOrTouchSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource(filename: "Unavailable.epub", fileExtension: "epub")
        let requested = expectation(description: "Actual provider load handler reports its failure")
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: UTType.epub.identifier) { completion, _, _ in
            requested.fulfill()
            let callback: NSItemProviderCompletionHandler? = completion
            callback?(nil, CocoaError(.fileReadNoPermission))
        }

        let error = await captureFailure(from: provider, typeID: UTType.epub.identifier, fixture: fixture)

        XCTAssertNotNil(error)
        await fulfillment(of: [requested], timeout: 3)
        try fixture.assertNoPublishedOrTemporaryImport(source: source)
    }

    func testDataWriteFailurePreservesExistingFileAndOriginalPayload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource(filename: "Data.pdf", fileExtension: "pdf")
        let provider = NSItemProvider(item: try Data(contentsOf: source) as NSData, typeIdentifier: UTType.pdf.identifier)
        let blockedDirectory = fixture.root.appendingPathComponent("NotADirectory")
        let previous = Data("Existing unrelated file".utf8)
        try previous.write(to: blockedDirectory)

        let error = await captureFailure(from: provider, typeID: UTType.pdf.identifier, fixture: fixture,
                                         temporaryDirectory: blockedDirectory)

        XCTAssertNotNil(error)
        XCTAssertEqual(try Data(contentsOf: blockedDirectory), previous)
        try fixture.assertNoPublishedOrTemporaryImport(source: source)
    }

    func testCancellationDuringProviderLoadDiscardsOnlyOwnedLateCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource(filename: "Cancelled.bin", fileExtension: "epub")
        let entered = expectation(description: "Provider load is suspended before yielding its URL")
        let held = HeldShareAttachment(source: source, entered: entered)
        defer { held.release() }
        let provider = held.provider(typeIdentifier: UTType.epub.identifier)
        let task = Task { try await ShareViewController.loadFileURL(from: provider, typeIdentifier: UTType.epub.identifier,
                                                                   temporaryDirectory: fixture.temporaryDirectory) }
        await fulfillment(of: [entered], timeout: 3)

        task.cancel()
        held.release()
        do { _ = try await task.value; XCTFail("A cancelled load must not publish its late temporary file") }
        catch { XCTAssertTrue(error is CancellationError) }

        try fixture.assertNoPublishedOrTemporaryImport(source: source)
    }

    func testAlreadyCancelledLoadDoesNotMaterializeAnAttachment() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource(filename: "Early.bin", fileExtension: "epub")
        let provider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.epub.identifier)
        let task = Task { try await ShareViewController.loadFileURL(from: provider, typeIdentifier: UTType.epub.identifier,
                                                                   temporaryDirectory: fixture.temporaryDirectory) }
        task.cancel()

        do { _ = try await task.value; XCTFail("A cancelled request must not begin loading") }
        catch { XCTAssertTrue(error is CancellationError) }

        try fixture.assertNoPublishedOrTemporaryImport(source: source)
    }

    func testUnsupportedTypeCannotBeRenamedIntoAnAcceptedBook() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource(filename: "Unsupported.epub", fileExtension: "epub")
        let provider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.plainText.identifier)

        let captured = await captureFailure(from: provider, typeID: UTType.plainText.identifier, fixture: fixture)
        let error = try XCTUnwrap(captured) as NSError

        XCTAssertEqual(error.domain, "ShareViewController")
        XCTAssertEqual(error.code, 101)
        try fixture.assertNoPublishedOrTemporaryImport(source: source)
    }

    private func captureFailure(from provider: NSItemProvider, typeID: String, fixture: Fixture,
                                fileManager: FileManager = .default, temporaryDirectory: URL? = nil) async -> Error? {
        do {
            _ = try await ShareViewController.loadFileURL(from: provider, typeIdentifier: typeID, fileManager: fileManager,
                                                          temporaryDirectory: temporaryDirectory ?? fixture.temporaryDirectory)
            XCTFail("Materialization must report the controlled failure")
            return nil
        } catch { return error }
    }

    @MainActor
    private final class Fixture {
        let suite = "share-attachment-\(UUID().uuidString)"
        let defaults: UserDefaults
        let root: URL
        let temporaryDirectory: URL
        let inboxDirectory: URL
        let libraryDirectory: URL
        let inboxFileManager: ShareInboxFileManager
        let library: LibraryStore
        private let markerBytes = Data("Unrelated temporary evidence".utf8)
        private var sourceContents: [URL: Data] = [:]

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite).resolvingSymlinksInPath()
            temporaryDirectory = root.appendingPathComponent("temporary")
            let container = root.appendingPathComponent("group")
            inboxDirectory = container.appendingPathComponent(SharedContainerInbox.inboxSubpath)
            libraryDirectory = root.appendingPathComponent("library")
            for directory in [root.appendingPathComponent("sources"), temporaryDirectory, inboxDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try markerBytes.write(to: temporaryDirectory.appendingPathComponent("unrelated.txt"))
            inboxFileManager = ShareInboxFileManager(container: container)
            library = LibraryStore(defaults: defaults, importDirectory: libraryDirectory)
        }

        func makeSource(filename: String, fileExtension: String) throws -> URL {
            let generated: URL
            if fileExtension == "pdf" {
                generated = try PdfFixture.createSinglePage(title: "Shared PDF", bodyText: filename)
            } else {
                generated = try EpubFixture.createWithChapter(body: "Shared EPUB source: " + filename)
            }
            defer { try? FileManager.default.removeItem(at: generated) }
            let source = root.appendingPathComponent("sources").appendingPathComponent(filename)
            try FileManager.default.moveItem(at: generated, to: source)
            sourceContents[source] = try Data(contentsOf: source)
            return source
        }

        func assertImport(materialized: URL, source: URL, fileExtension: String,
                          file: StaticString = #filePath, line: UInt = #line) async throws {
            let original = try XCTUnwrap(sourceContents[source], file: file, line: line)
            XCTAssertEqual(materialized.pathExtension, fileExtension, file: file, line: line)
            XCTAssertEqual(materialized.resolvingSymlinksInPath().deletingLastPathComponent(), temporaryDirectory,
                           file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: materialized), original, file: file, line: line)
            let dropped = try SharedContainerInbox.dropIntoInbox(source: materialized, fileManager: inboxFileManager)
            let pending = SharedContainerImporter.pendingFiles(in: inboxDirectory)
            XCTAssertTrue(pending.contains(dropped), file: file, line: line)
            let outcomes = await SharedContainerImporter.drainAsync(urls: pending, into: library)
            let outcome = try XCTUnwrap(outcomes.first { $0.url == dropped }, file: file, line: line)
            let bookID = try XCTUnwrap(outcome.importedBookID, file: file, line: line)
            XCTAssertNil(outcome.error, file: file, line: line)
            XCTAssertEqual(bookID, try BookContentIdentity.hash(of: source), file: file, line: line)
            let reloaded = LibraryStore(defaults: defaults, importDirectory: libraryDirectory)
            let book = try XCTUnwrap(reloaded.books.first { $0.id == bookID }, file: file, line: line)
            XCTAssertEqual(book.fileType.rawValue, fileExtension, file: file, line: line)
            let durable = try LibraryBookmarkAccess.resolveBookBookmark(book.bookmark).url
            XCTAssertTrue(durable.resolvingSymlinksInPath().path.hasPrefix(libraryDirectory.path + "/"), file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: durable), original, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: source), original, file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.path), file: file, line: line)
        }

        func assertNoPublishedOrTemporaryImport(source: URL, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), ["unrelated.txt"],
                           file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: temporaryDirectory.appendingPathComponent("unrelated.txt")), markerBytes,
                           file: file, line: line)
            XCTAssertTrue(SharedContainerImporter.pendingFiles(in: inboxDirectory).isEmpty, file: file, line: line)
            XCTAssertTrue(library.books.isEmpty, file: file, line: line)
            let original = try XCTUnwrap(sourceContents[source], file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: source), original, file: file, line: line)
        }

        func cleanUp() {
            try? library.flushPersistenceSync()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
#endif
