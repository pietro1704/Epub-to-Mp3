import XCTest
@testable import EpubToMp3

final class PublicDomainDiscoveryTests: XCTestCase {
    @MainActor
    func testGutenbergServiceUnavailableKeepsEditionAndRetryImportsReadableEPUB() async throws {
        let downloadURL = try XCTUnwrap(URL(string: "https://www.gutenberg.org/ebooks/57001.epub3.images"))
        let mirrorURL = try XCTUnwrap(URL(string: "https://gutenberg.pglaf.org/cache/epub/57001/pg57001-images-3.epub"))
        let searchJSON = """
        {"next": null, "results": [{
          "id": 57001, "title": "Papeis Avulsos", "authors": [{"name": "Machado de Assis"}],
          "languages": ["pt"], "copyright": false,
          "formats": {"application/epub+zip": "\(downloadURL.absoluteString)"}
        }]}
        """

        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "library.discovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? files.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let mirrorHTML = root.appendingPathComponent("mirror-unavailable")
        let originalHTML = root.appendingPathComponent("original-unavailable")
        let epub = root.appendingPathComponent("downloaded-epub")
        let fixture = try EpubFixture.create()
        defer { try? files.removeItem(at: fixture) }
        let expectedBytes = try Data(contentsOf: fixture)
        try expectedBytes.write(to: epub)
        let serviceUnavailable = Data("<html><title>503 Service Unavailable</title></html>".utf8)
        try serviceUnavailable.write(to: mirrorHTML)
        try serviceUnavailable.write(to: originalHTML)

        var downloadRequests: [URL] = []
        let catalog = PublicDomainCatalog(searchData: { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(searchJSON.utf8), response)
        }, downloadFile: { request, provider in
            XCTAssertEqual(provider, .gutenberg)
            let url = try XCTUnwrap(request.url)
            downloadRequests.append(url)
            let failed = downloadRequests.count <= 2
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: failed ? 503 : 200, httpVersion: nil,
                headerFields: ["Content-Type": failed ? "text/html" : "application/epub+zip"]
            ))
            guard failed else { return (epub, response) }
            return (url == mirrorURL ? mirrorHTML : originalHTML, response)
        })
        let store = LibraryStore(defaults: defaults, importDirectory: root.appendingPathComponent("Library"))
        var importedFiles: [URL] = []
        let discovery = PublicDomainDiscovery(catalog: catalog) { file in
            importedFiles.append(file)
            return try await store.importBookAsync(from: file)
        }

        await waitForIdle(discovery, after: "Gutenberg search") {
            discovery.search("Papeis Avulsos", language: .portuguese)
        }
        let edition = try XCTUnwrap(discovery.editions.first)
        XCTAssertEqual(edition.id, .init(provider: .gutenberg, number: 57001))
        XCTAssertEqual(edition.title, "Papeis Avulsos")

        await waitForIdle(discovery, after: "Gutenberg 503") {
            discovery.download(edition)
        }
        XCTAssertEqual(downloadRequests, [mirrorURL, downloadURL])
        XCTAssertEqual(discovery.editions.map(\.id), [edition.id])
        XCTAssertEqual(discovery.message, L10n.string("discovery.downloadFailed"))
        XCTAssertNil(discovery.importedBook)
        XCTAssertTrue(importedFiles.isEmpty)
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertFalse(files.fileExists(atPath: mirrorHTML.path))
        XCTAssertFalse(files.fileExists(atPath: originalHTML.path))

        let retryEdition = try XCTUnwrap(discovery.editions.first)
        await waitForIdle(discovery, after: "successful retry and library import") {
            discovery.download(retryEdition)
        }
        XCTAssertEqual(downloadRequests, [mirrorURL, downloadURL, mirrorURL])
        XCTAssertEqual(discovery.message, L10n.string("discovery.imported"))
        XCTAssertEqual(importedFiles.count, 1)
        let staged = try XCTUnwrap(importedFiles.first)
        XCTAssertFalse(files.fileExists(atPath: staged.path))

        let book = try XCTUnwrap(discovery.importedBook)
        XCTAssertEqual(book.fileType, .epub)
        XCTAssertEqual(book.title, EpubFixture.title)
        XCTAssertEqual(store.books.map(\.id), [book.id])
        let opened = try await store.openBookFileAsync(id: book.id)
        XCTAssertEqual(try Data(contentsOf: opened), expectedBytes)
    }

    @MainActor
    func testGutendexFailureKeepsBothBrazilianEditionsWithDistinctSources() async {
        let catalog = PublicDomainCatalog(searchData: { _ in
            throw URLError(.cannotConnectToHost)
        }, downloadFile: { _, _ in
            XCTFail("Search must not download a book")
            throw URLError(.unsupportedURL)
        })
        let discovery = PublicDomainDiscovery(catalog: catalog) { _ in
            XCTFail("Search must not import a book")
            throw URLError(.unsupportedURL)
        }

        await waitForIdle(discovery, after: "unavailable Gutendex search") {
            discovery.search("Casmurro", language: .portuguese)
        }
        XCTAssertEqual(discovery.message, L10n.string("discovery.gutenbergUnavailable"))
        XCTAssertEqual(discovery.editions.map(\.id), [
            .init(provider: .brasiliana, number: 4828), .init(provider: .camara, number: 28739),
        ])
        XCTAssertEqual(discovery.editions.map(\.title), ["Dom Casmurro", "Dom Casmurro"])
        XCTAssertEqual(discovery.editions.map { $0.source.absoluteString }, [
            "https://digital.bbm.usp.br/handle/bbm/4828",
            "https://livraria.camara.leg.br/produto/dom-casmurro/",
        ])
        XCTAssertEqual(discovery.editions.map(\.attribution), [
            "\(L10n.string("discovery.provider.brasiliana")) · \(L10n.string("discovery.rights.brasiliana"))",
            "\(L10n.string("discovery.provider.camara")) · \(L10n.string("discovery.rights.camara"))",
        ])
        XCTAssertFalse(discovery.hasMore)
    }

    @MainActor
    private func waitForIdle(_ discovery: PublicDomainDiscovery, after operation: String, start: () -> Void) async {
        let settled = expectation(description: "Discovery returns to idle after \(operation)")
        discovery.onChange = { [weak discovery] in
            guard let discovery, discovery.activity == .idle else { return }
            discovery.onChange = nil
            settled.fulfill()
        }
        defer { discovery.onChange = nil }
        start()
        await fulfillment(of: [settled], timeout: 5)
    }
}
