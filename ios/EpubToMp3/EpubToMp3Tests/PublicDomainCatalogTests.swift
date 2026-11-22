import XCTest
@testable import EpubToMp3

final class PublicDomainCatalogTests: XCTestCase {
    func testSearchUsesUSRightsAndSelectedLanguage() throws {
        let url = PublicDomainCatalog.searchURL(query: "Machado & Assis +", language: .portuguese, page: 2)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "search" }?.value, "Machado & Assis +")
        XCTAssertEqual(items.first { $0.name == "copyright" }?.value, "false")
        XCTAssertEqual(items.first { $0.name == "languages" }?.value, "pt")
        XCTAssertEqual(items.first { $0.name == "page" }?.value, "2")
    }

    func testOnlyKnownUSPublicDomainEditionsWithSupportedTrustedFilesAreListed() throws {
        let response = """
        {
          "next": "https://gutendex.com/books/?page=2",
          "results": [
            {
              "id": 55752, "title": "Dom Casmurro", "authors": [{"name": "Machado de Assis"}],
              "languages": ["pt"], "copyright": false,
              "formats": {
                "application/pdf": "https://www.gutenberg.org/cache/epub/55752/edition.pdf",
                "application/epub+zip": "https://www.gutenberg.org/ebooks/55752.epub3.images"
              }
            },
            {
              "id": 2, "title": "PDF edition", "authors": [], "languages": ["en"], "copyright": false,
              "formats": {
                "application/epub+zip": "https://gutenberg.example/edition.epub",
                "application/pdf": "https://www.gutenberg.org/cache/epub/2/edition.pdf"
              }
            },
            {
              "id": 3, "title": "Rights unknown", "authors": [], "languages": ["en"], "copyright": null,
              "formats": {"application/epub+zip": "https://www.gutenberg.org/ebooks/3.epub3.images"}
            },
            {
              "id": 4, "title": "Copyrighted edition", "authors": [], "languages": ["en"], "copyright": true,
              "formats": {"application/epub+zip": "https://www.gutenberg.org/ebooks/4.epub3.images"}
            },
            {
              "id": 5, "title": "Unsupported edition", "authors": [], "languages": ["en"], "copyright": false,
              "formats": {"text/plain": "https://www.gutenberg.org/ebooks/5.txt"}
            }
          ]
        }
        """
        let page = try PublicDomainCatalog.decode(Data(response.utf8))
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.editions.map(\.id.number), [55752, 2])
        XCTAssertEqual(page.editions.map { $0.files.map { $0.format } }, [[.epub, .pdf], [.pdf]])
        XCTAssertEqual(page.editions.first?.source.absoluteString, "https://www.gutenberg.org/ebooks/55752")
        XCTAssertEqual(page.editions.first?.languages, ["pt"])
    }

    func testServiceErrorPageNeverBecomesAnEmptySuccessfulResult() {
        XCTAssertThrowsError(try PublicDomainCatalog.decode(Data("<html>Unavailable</html>".utf8)))
    }

    func testBrazilianEditionsMergeOnFirstPageWithAccentInsensitiveTitleAndAuthorMatching() async throws {
        let catalog = PublicDomainCatalog(searchData: { request in
            let json = """
            {
              "next": "https://gutendex.com/books/?page=2",
              "results": [{
                "id": 4828, "title": "Gutenberg edition", "authors": [], "languages": ["pt"], "copyright": false,
                "formats": {"application/epub+zip": "https://www.gutenberg.org/ebooks/4828.epub3.images"}
              }]
            }
            """
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(json.utf8), response)
        })

        let first = try await catalog.search(query: "Cásmurro MÁCHADO", language: .portuguese, page: 1)
        XCTAssertEqual(first.editions.map(\.id.provider), [.brasiliana, .camara, .gutenberg])
        XCTAssertEqual(Set(first.editions.map(\.id)).count, 3)
        XCTAssertTrue(first.hasMore)
        XCTAssertFalse(first.gutenbergUnavailable)
        XCTAssertEqual(first.editions.first?.source.absoluteString, "https://digital.bbm.usp.br/handle/bbm/4828")
        XCTAssertEqual(first.editions.first?.files.map(\.format), [.pdf])

        let author = try await catalog.search(query: "Assis", language: .all, page: 1)
        XCTAssertEqual(author.editions.first?.id.provider, .brasiliana)
        let second = try await catalog.search(query: "Casmurro", language: .all, page: 2)
        XCTAssertEqual(second.editions.map(\.id.provider), [.gutenberg])
        let english = try await catalog.search(query: "Casmurro", language: .english, page: 1)
        XCTAssertEqual(english.editions.map(\.id.provider), [.gutenberg])
        let unrelated = try await catalog.search(query: "Brás Cubas", language: .all, page: 1)
        XCTAssertEqual(unrelated.editions.map(\.id.provider), [.gutenberg])
    }

    @MainActor
    func testBrazilianPDFCanBeImportedWhenGutendexIsUnavailable() async throws {
        let catalog = PublicDomainCatalog(searchData: { _ in
            throw URLError(.cannotConnectToHost)
        }, downloadFile: { request, provider in
            XCTAssertEqual(provider, .brasiliana)
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.absoluteString, "https://digital.bbm.usp.br/bitstream/bbm/4828/1/002038_COMPLETO.pdf")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/octet-stream"]))
            let fixture = try PdfFixture.createSinglePage(title: "Dom Casmurro", author: "Machado de Assis")
            return (fixture, response)
        })
        let result = try await catalog.search(query: "Casmurro", language: .all, page: 1)
        let edition = try XCTUnwrap(result.editions.first { $0.id.provider == .brasiliana })
        XCTAssertEqual(result.editions.count, 2)
        XCTAssertFalse(result.hasMore)
        XCTAssertTrue(result.gutenbergUnavailable)

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("discovery-library-\(UUID())")
        let suite = "library.discovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? manager.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = LibraryStore(defaults: defaults, importDirectory: root)
        let file = try await catalog.download(edition)
        defer { try? manager.removeItem(at: file.deletingLastPathComponent()) }
        let book = try await store.importBookAsync(from: file)
        XCTAssertEqual(book.fileType, .pdf)
        XCTAssertEqual(store.books.map(\.id), [book.id])
    }

    func testBrazilianDownloadRejectsRedirectToOtherProviderEvenWithValidPDF() async throws {
        let catalog = PublicDomainCatalog(searchData: { _ in
            throw URLError(.cannotConnectToHost)
        }, downloadFile: { _, _ in
            let redirect = try XCTUnwrap(URL(string: "https://www.gutenberg.org/ebook.pdf"))
            let response = try XCTUnwrap(HTTPURLResponse(url: redirect, statusCode: 200,
                                                         httpVersion: nil, headerFields: ["Content-Type": "application/pdf"]))
            let fixture = try PdfFixture.createSinglePage(title: "Dom Casmurro", author: "Machado de Assis")
            return (fixture, response)
        })
        let result = try await catalog.search(query: "Casmurro", language: .all, page: 1)
        let edition = try XCTUnwrap(result.editions.first { $0.id.provider == .brasiliana })
        do {
            let file = try await catalog.download(edition)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            XCTFail("A PDF from another provider must be rejected")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    @MainActor
    func testCamaraPrefersEPUBAndUsesPDFWhenEPUBResponseHasAnUnreviewedDestination() async throws {
        let epubURL = "https://bd-rest.camara.leg.br/server/api/core/bitstreams/2b30f5a5-5e5f-49fd-9db7-f4a6c31c457f/content"
        let pdfURL = "https://bd-rest.camara.leg.br/server/api/core/bitstreams/8835c1ee-9566-4465-bc91-ce7003a6d4de/content"
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("camara-library-\(UUID())")
        let suite = "library.discovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? files.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = LibraryStore(defaults: defaults, importDirectory: root)
        for redirected in [false, true] {
            var requested: [String] = []
            let catalog = PublicDomainCatalog(searchData: { _ in
                throw URLError(.cannotConnectToHost)
            }, downloadFile: { request, provider in
                XCTAssertEqual(provider, .camara)
                let url = try XCTUnwrap(request.url)
                requested.append(url.absoluteString)
                let isEPUB = url.absoluteString == epubURL
                // The PDF bitstream is curated, but it is not an approved destination for the EPUB.
                let target = isEPUB && redirected ? try XCTUnwrap(URL(string: pdfURL)) : url
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: target, statusCode: 200, httpVersion: nil, headerFields: nil))
                let fixture = isEPUB ? try EpubFixture.create() : try PdfFixture.createSinglePage()
                return (fixture, response)
            })
            let result = try await catalog.search(query: "Cásmurro", language: .portuguese, page: 1)
            let edition = try XCTUnwrap(result.editions.first { $0.id.provider == .camara })
            let file = try await catalog.download(edition)
            defer { try? files.removeItem(at: file.deletingLastPathComponent()) }
            let book = try await store.importBookAsync(from: file)
            XCTAssertEqual(book.fileType, redirected ? .pdf : .epub)
            XCTAssertEqual(requested, redirected ? [epubURL, pdfURL] : [epubURL])
        }
    }

    func testCamaraRejectsUncuratedBitstreamBeforeSendingARequest() async throws {
        let url = try XCTUnwrap(URL(string: "https://bd-rest.camara.leg.br/server/api/core/bitstreams/other/content"))
        let edition = PublicDomainCatalog.Edition(
            id: .init(provider: .camara, number: 28739), title: "Dom Casmurro",
            authors: ["Machado de Assis"], languages: ["pt"], files: [(.epub, url)], source: url)
        let catalog = PublicDomainCatalog(downloadFile: { _, _ in
            XCTFail("Only the curated Câmara bitstream may be requested")
            throw URLError(.unsupportedURL)
        })
        do {
            let file = try await catalog.download(edition)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            XCTFail("An uncurated bitstream must be rejected")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testCancelledGutendexSearchDoesNotReturnLocalResults() async {
        let catalog = PublicDomainCatalog(searchData: { _ in throw URLError(.cancelled) })
        for query in ["Casmurro", "Papéis"] {
            do {
                _ = try await catalog.search(query: query, language: .all, page: 1)
                XCTFail("A cancelled search must throw")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    @MainActor
    // MARK: - Untrusted catalog and file size

    func testSearchResponseAboveTheCapIsRejectedBeforeDecodingEvenIfItIsValidJSON() async throws {
        let padded = Data(repeating: 0x20, count: 64) + Data(#"{"results":[],"next":null}"#.utf8)
        let capped = PublicDomainCatalog(searchData: { request in
            (padded, try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, maximumSearchBytes: 32)
        do {
            _ = try await capped.search(query: "dom", language: .all, page: 2)
            XCTFail("A search response above the cap must not be decoded")
        } catch is CancellationError {
            XCTFail("An oversized response is a failure, not a cancellation")
        } catch {}
        // The same response is accepted under the default cap, so the cap is what rejected it.
        let normal = PublicDomainCatalog(searchData: { request in
            (padded, try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let page = try await normal.search(query: "dom", language: .all, page: 2)
        XCTAssertTrue(page.editions.isEmpty)
    }

    func testDownloadedFileAboveTheCapIsRejectedAndNothingIsStaged() async throws {
        let fixture = try EpubFixture.create()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: fixture) }
        let size = try XCTUnwrap(manager.attributesOfItem(atPath: fixture.path)[.size] as? NSNumber).intValue
        func catalog(maximumDownloadBytes: Int) -> PublicDomainCatalog {
            PublicDomainCatalog(downloadFile: { request, _ in
                let file = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try manager.copyItem(at: fixture, to: file)
                return (file, try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
            }, maximumDownloadBytes: maximumDownloadBytes)
        }
        do {
            _ = try await catalog(maximumDownloadBytes: size - 1).download(testEdition())
            XCTFail("A file above the cap must be rejected")
        } catch {}
        let accepted = try await catalog(maximumDownloadBytes: size).download(testEdition())
        defer { try? manager.removeItem(at: accepted.deletingLastPathComponent()) }
        XCTAssertEqual(accepted.pathExtension, "epub")
    }

    func testHTTP200WithAnHTMLBodyIsNotImportedAsABook() async throws {
        let manager = FileManager.default
        let catalog = PublicDomainCatalog(downloadFile: { request, _ in
            let file = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("<html><body>Service unavailable</body></html>".utf8).write(to: file)
            return (file, try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        do {
            _ = try await catalog.download(testEdition())
            XCTFail("An HTML page is not an EPUB")
        } catch {}
    }

    func testEPUBDownloadUsesTheLibraryIdentityAndKeepsOneBookOnRetry() async throws {
        let fixture = try EpubFixture.create()
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("discovery-library-\(UUID())")
        defer {
            try? manager.removeItem(at: fixture)
            try? manager.removeItem(at: root)
        }
        let suite = "library.discovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults, importDirectory: root)
        var requested: [URL] = []
        let catalog = PublicDomainCatalog(downloadFile: { request, _ in
            let url = try XCTUnwrap(request.url)
            requested.append(url)
            let file = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try manager.copyItem(at: fixture, to: file)
            return (file, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let edition = testEdition()
        let firstFile = try await catalog.download(edition)
        defer { try? manager.removeItem(at: firstFile.deletingLastPathComponent()) }
        let first = try await store.importBookAsync(from: firstFile)
        let secondFile = try await catalog.download(edition)
        defer { try? manager.removeItem(at: secondFile.deletingLastPathComponent()) }
        let second = try await store.importBookAsync(from: secondFile)
        XCTAssertEqual(first.fileType, .epub)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(store.books.map(\.id), [first.id])
        XCTAssertEqual(requested, [edition.files[0].url, edition.files[0].url])
    }

    func testUnavailableGutendexFindsReviewedEditionsOnFirstPageByTitleAndAuthor() async throws {
        let catalog = PublicDomainCatalog(searchData: { _ in throw URLError(.timedOut) })
        let matches: [(query: String, language: PublicDomainCatalog.Language, number: Int)] = [
            ("Papéis ASSIS", .portuguese, 57001),
            ("Alice Carroll", .english, 11),
            ("Pride Austen", .english, 1342),
            ("Finn Twain", .all, 76),
        ]
        for match in matches {
            let page = try await catalog.search(query: match.query, language: match.language, page: 1)
            XCTAssertTrue(page.gutenbergUnavailable)
            XCTAssertFalse(page.hasMore)
            XCTAssertEqual(page.editions.map(\.id), [.init(provider: .gutenberg, number: match.number)])
            XCTAssertEqual(page.editions.first?.source.absoluteString,
                           "https://www.gutenberg.org/ebooks/\(match.number)")
            XCTAssertEqual(page.editions.first?.files.map(\.format), [.epub])
        }

        for (language, page) in [(PublicDomainCatalog.Language.english, 1), (.portuguese, 2)] {
            do {
                _ = try await catalog.search(query: "Papéis", language: language, page: page)
                XCTFail("Reviewed titles are limited to matching languages on the first page")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
            }
        }
    }

    func testReviewedEditionFromFallbackDownloadsItsVerifiedEPUB() async throws {
        let mirror = "https://gutenberg.pglaf.org/cache/epub/57001/pg57001-images-3.epub"
        var requested: [String] = []
        let catalog = PublicDomainCatalog(searchData: { _ in
            throw URLError(.timedOut)
        }, downloadFile: { request, provider in
            XCTAssertEqual(provider, .gutenberg)
            let url = try XCTUnwrap(request.url)
            requested.append(url.absoluteString)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (try EpubFixture.create(), response)
        })
        let page = try await catalog.search(query: "Papéis", language: .portuguese, page: 1)
        let file = try await catalog.download(XCTUnwrap(page.editions.first))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(file.pathExtension, "epub")
        XCTAssertEqual(requested, [mirror])
    }

    func testHealthyGutendexKeepsItsOwnMatchesWithoutAddingReviewedRows() async throws {
        let catalog = PublicDomainCatalog(searchData: { request in
            let json = """
            {"results": [{
                "id": 57001, "title": "Papéis Avulsos", "authors": [{"name": "Machado de Assis"}],
                "languages": ["pt"], "copyright": false,
                "formats": {"application/epub+zip": "https://www.gutenberg.org/ebooks/57001.epub3.images"}
            }]}
            """
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(json.utf8), response)
        })
        let page = try await catalog.search(query: "Papéis", language: .portuguese, page: 1)
        XCTAssertFalse(page.gutenbergUnavailable)
        XCTAssertEqual(page.editions.map(\.title), ["Papéis Avulsos"])
        XCTAssertEqual(page.editions.first?.files.first?.url.host, "www.gutenberg.org")
    }

    func testVerifiedGutenbergMirrorIsTriedBeforeOfficialEPUBWithOneFormatLabel() async throws {
        let routes = [
            57001: "https://gutenberg.pglaf.org/cache/epub/57001/pg57001-images-3.epub",
            11: "https://gutenberg.pglaf.org/cache/epub/11/pg11-images-3.epub",
            1342: "https://gutenberg.pglaf.org/cache/epub/1342/pg1342.epub",
            76: "https://gutenberg.pglaf.org/cache/epub/76/pg76.epub",
        ]
        for (number, mirror) in routes {
            let original = "https://www.gutenberg.org/ebooks/\(number).epub3.images"
            let json = """
            {"results": [{
                "id": \(number), "title": "Edition", "authors": [], "languages": ["en"], "copyright": false,
                "formats": {
                    "application/epub+zip": "\(original)",
                    "application/pdf": "https://www.gutenberg.org/cache/epub/\(number)/edition.pdf"
                }
            }]}
            """
            let page = try PublicDomainCatalog.decode(Data(json.utf8))
            let edition = try XCTUnwrap(page.editions.first)
            XCTAssertEqual(edition.files.map(\.format), [.epub, .pdf])
            XCTAssertEqual(edition.detail.components(separatedBy: "EPUB").count, 2)
            XCTAssertEqual(edition.source.absoluteString, "https://www.gutenberg.org/ebooks/\(number)")
            XCTAssertEqual(edition.id.provider, .gutenberg)

            for mirrorAvailable in [true, false] {
                var requested: [String] = []
                let catalog = PublicDomainCatalog(downloadFile: { request, provider in
                    XCTAssertEqual(provider, .gutenberg)
                    let url = try XCTUnwrap(request.url)
                    requested.append(url.absoluteString)
                    if url.absoluteString == mirror && !mirrorAvailable {
                        throw URLError(.cannotConnectToHost)
                    }
                    let response = try XCTUnwrap(HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                    return (try EpubFixture.create(), response)
                })
                let file = try await catalog.download(edition)
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                XCTAssertEqual(file.pathExtension, "epub")
                XCTAssertEqual(requested, mirrorAvailable ? [mirror] : [mirror, original])
            }
        }
    }

    func testMirrorResponseRejectsUnreviewedDestinationsBeforeTryingOfficialFiles() async throws {
        let edition = testEdition(number: 11)
        let mirror = "https://gutenberg.pglaf.org/cache/epub/11/pg11-images-3.epub"
        let rejectedURLs = [
            "https://gutenberg.pglaf.org/cache/epub/11/unreviewed.epub",
            "https://gutenberg.pglaf.org/cache/epub/76/pg76.epub",
            "https://gutenberg.pglaf.org.example/cache/epub/11/pg11-images-3.epub",
            "http://gutenberg.pglaf.org/cache/epub/11/pg11-images-3.epub",
            "https://gutenberg.pglaf.org:444/cache/epub/11/pg11-images-3.epub",
            edition.files[0].url.absoluteString,
        ]
        for rejectedURL in rejectedURLs {
            var requested: [String] = []
            let catalog = PublicDomainCatalog(downloadFile: { request, _ in
                let url = try XCTUnwrap(request.url)
                requested.append(url.absoluteString)
                if url.absoluteString == mirror {
                    let response = try XCTUnwrap(HTTPURLResponse(
                        url: XCTUnwrap(URL(string: rejectedURL)), statusCode: 200, httpVersion: nil, headerFields: nil))
                    return (try EpubFixture.create(), response)
                }
                if url == edition.files[0].url {
                    throw URLError(.cannotConnectToHost)
                }
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (try PdfFixture.createSinglePage(title: edition.title, author: "Test"), response)
            })
            let file = try await catalog.download(edition)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            XCTAssertEqual(file.pathExtension, "pdf", rejectedURL)
            XCTAssertEqual(requested, [mirror] + edition.files.map { $0.url.absoluteString }, rejectedURL)
        }
    }

    func testMirrorCancellationDoesNotTryOfficialFiles() async {
        var requested: [String] = []
        let catalog = PublicDomainCatalog(downloadFile: { request, _ in
            requested.append(try XCTUnwrap(request.url).absoluteString)
            throw URLError(.cancelled)
        })

        do {
            _ = try await catalog.download(testEdition(number: 76))
            XCTFail("A cancelled mirror download must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(requested, ["https://gutenberg.pglaf.org/cache/epub/76/pg76.epub"])
        }
    }

    func testInvalidEPUBFallsBackToPDF() async throws {
        let edition = testEdition()
        var requested: [URL] = []
        let catalog = PublicDomainCatalog(downloadFile: { request, _ in
            let url = try XCTUnwrap(request.url)
            requested.append(url)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            if url == edition.files[0].url {
                try Data("<html>Maintenance</html>".utf8).write(to: file)
            } else {
                let fixture = try PdfFixture.createSinglePage(title: edition.title, author: "Machado de Assis")
                try FileManager.default.moveItem(at: fixture, to: file)
            }
            return (file, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })

        let file = try await catalog.download(edition)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(file.pathExtension, "pdf")
        XCTAssertEqual(requested, edition.files.map { $0.url })
    }

    func testCancelledDownloadStopsBeforePDFAndCanBeRetried() async throws {
        let edition = testEdition()
        var requested: [URL] = []
        let started = expectation(description: "download requested")
        let catalog = PublicDomainCatalog(downloadFile: { request, _ in
            let url = try XCTUnwrap(request.url)
            requested.append(url)
            if requested.count == 1 {
                started.fulfill()
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            throw URLError(.cannotConnectToHost)
        })

        let pending = Task { try await catalog.download(edition) }
        await fulfillment(of: [started], timeout: 3)
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("A cancelled download must throw")
        } catch is CancellationError {
            XCTAssertEqual(requested, [edition.files[0].url])
        }
        do {
            _ = try await catalog.download(edition)
            XCTFail("A server failure must throw")
        } catch {
            XCTAssertEqual(requested, [edition.files[0].url] + edition.files.map { $0.url })
        }
    }

    func testDownloadCancellationErrorDoesNotAttemptPDF() async {
        let edition = testEdition()
        var requested: [URL] = []
        let catalog = PublicDomainCatalog(downloadFile: { request, _ in
            requested.append(try XCTUnwrap(request.url))
            throw CancellationError()
        })

        do {
            _ = try await catalog.download(edition)
            XCTFail("A cancelled download must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(requested, [edition.files[0].url])
        }
    }

    private func testEdition(number: Int = 55752) -> PublicDomainCatalog.Edition {
        PublicDomainCatalog.Edition(id: .init(provider: .gutenberg, number: number),
                                    title: "Dom Casmurro", authors: ["Machado de Assis"],
                                    languages: ["pt"], files: [
            (.epub, URL(string: "https://www.gutenberg.org/ebooks/\(number).epub3.images")!),
            (.pdf, URL(string: "https://www.gutenberg.org/cache/epub/\(number)/edition.pdf")!),
        ], source: URL(string: "https://www.gutenberg.org/ebooks/\(number)")!)
    }
}
