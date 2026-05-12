import XCTest
import UniformTypeIdentifiers
@testable import EpubToMp3

/// Exercises `LibraryDropHandler` — the shared drag-and-drop entry
/// point used by both `LibraryView` (iPhone grid) and `LibrarySidebar`
/// (iPad / macOS column). The handler is decoupled from SwiftUI so we
/// can drive it directly with synthetic `NSItemProvider` payloads.
final class LibraryDragDropTests: XCTestCase {

    // MARK: Helpers

    /// Writes a small payload to a temp `.epub` file so the system
    /// classifies the resulting `NSItemProvider` as an EPUB.
    private func makeEpubFile(contents: String = "drop-test-epub") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drag-\(UUID().uuidString).epub")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Provider that advertises an EPUB on disk. `loadFileRepresentation`
    /// will hand the handler a temp copy.
    private func epubProvider(url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.epub.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    /// Provider that advertises a plain-text payload — the handler
    /// must ignore it without crashing or surfacing an error.
    private func plainTextProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data("hello".utf8), nil)
            return nil
        }
        return provider
    }

    /// Provider whose file-representation loader fails — the handler
    /// must capture the error and surface it through the completion
    /// closure exactly once.
    private func failingEpubProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.epub.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let err = NSError(
                domain: "DropTest",
                code: 99,
                userInfo: [NSLocalizedDescriptionKey: "synthetic-failure"]
            )
            completion(nil, false, err)
            return nil
        }
        return provider
    }

    private var didFinish = false

    private func runHandler(
        providers: [NSItemProvider],
        importer: @escaping (URL) throws -> Void,
        timeout: TimeInterval = 4
    ) -> (firstError: String?, imported: Int, accepted: Bool) {
        didFinish = false
        var capturedError: String?
        var capturedImported = 0
        let accepted = LibraryDropHandler.handle(
            providers: providers,
            importer: importer
        ) { firstError, imported in
            capturedError = firstError
            capturedImported = imported
            self.didFinish = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !didFinish {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(didFinish, "drop completion never fired")
        return (capturedError, capturedImported, accepted)
    }

    // MARK: Tests

    func testSingleEpubProviderTriggersImport() throws {
        let url = try makeEpubFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var importedURLs: [URL] = []
        let result = runHandler(
            providers: [epubProvider(url: url)],
            importer: { importedURLs.append($0) }
        )

        XCTAssertTrue(result.accepted)
        XCTAssertNil(result.firstError)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(importedURLs.count, 1)
        XCTAssertEqual(importedURLs.first?.pathExtension, "epub")
        // Imported URL should be inside the scratch dir — proves the
        // handler copied the file before invoking the importer.
        XCTAssertTrue(
            importedURLs.first?.path.contains("EpubToMp3-Drop") ?? false,
            "expected imported url under scratch dir, got \(importedURLs.first?.path ?? "nil")"
        )
    }

    func testMultipleEpubProvidersImportEachOne() throws {
        let a = try makeEpubFile(contents: "a")
        let b = try makeEpubFile(contents: "b")
        let c = try makeEpubFile(contents: "c")
        defer {
            for u in [a, b, c] { try? FileManager.default.removeItem(at: u) }
        }

        var importedURLs: [URL] = []
        let lock = NSLock()
        let result = runHandler(
            providers: [
                epubProvider(url: a),
                epubProvider(url: b),
                epubProvider(url: c),
            ],
            importer: { url in
                lock.lock(); importedURLs.append(url); lock.unlock()
            }
        )

        XCTAssertTrue(result.accepted)
        XCTAssertNil(result.firstError)
        XCTAssertEqual(result.imported, 3)
        XCTAssertEqual(importedURLs.count, 3)
    }

    func testUnsupportedProviderIsIgnored() {
        var importerCalls = 0
        let result = runHandler(
            providers: [plainTextProvider()],
            importer: { _ in importerCalls += 1 }
        )

        XCTAssertFalse(
            result.accepted,
            "unsupported drops must be rejected so SwiftUI shows the right cursor"
        )
        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(importerCalls, 0)
        XCTAssertNil(
            result.firstError,
            "unsupported types should NOT surface an error to the user"
        )
    }

    func testMixedSupportedAndUnsupportedImportsOnlySupported() throws {
        let url = try makeEpubFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var importedURLs: [URL] = []
        let result = runHandler(
            providers: [
                epubProvider(url: url),
                plainTextProvider(),
            ],
            importer: { importedURLs.append($0) }
        )

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(importedURLs.count, 1)
    }

    func testProviderLoadFailureSurfacesError() {
        var importerCalls = 0
        let result = runHandler(
            providers: [failingEpubProvider()],
            importer: { _ in importerCalls += 1 }
        )

        XCTAssertTrue(result.accepted, "epub UTI should still be accepted even if load fails")
        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(importerCalls, 0)
        // The system wraps `loadFileRepresentation` errors with its
        // own NSItemProvider localised message — we don't try to
        // unwrap it (that's locale-dependent) but we DO require that
        // _something_ ended up in the alert state so the user knows
        // the drop wasn't silent.
        XCTAssertNotNil(
            result.firstError,
            "a failing load must propagate an error to the alert"
        )
        XCTAssertFalse(
            result.firstError?.isEmpty ?? true,
            "alert message must be non-empty"
        )
    }

    func testImporterThrowSurfacesError() throws {
        let url = try makeEpubFile()
        defer { try? FileManager.default.removeItem(at: url) }

        struct ImportError: LocalizedError {
            var errorDescription: String? { "import-blew-up" }
        }

        let result = runHandler(
            providers: [epubProvider(url: url)],
            importer: { _ in throw ImportError() }
        )

        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(result.firstError, "import-blew-up")
    }

    func testAcceptedTypesIncludesEpub() {
        let types = LibraryDropHandler.acceptedTypes
        XCTAssertTrue(types.contains(.epub))
        #if os(macOS)
        XCTAssertTrue(
            types.contains(.fileURL),
            "macOS Finder drops advertise file URLs — must be in the accepted list"
        )
        #else
        XCTAssertFalse(
            types.contains(.fileURL),
            "iOS Files app does not surface file URL providers — should not be in the list"
        )
        #endif
    }
}
