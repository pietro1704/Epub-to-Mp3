import Foundation

struct PublicDomainCatalog {
    enum Language: String, CaseIterable {
        case all, portuguese = "pt", english = "en"

        var label: String { L10n.string("discovery.language.\(rawValue)") }
    }

    enum Format: String, CaseIterable {
        case epub, pdf

        var mediaType: String { self == .epub ? "application/epub+zip" : "application/pdf" }
        var signature: Data { self == .epub ? Data([0x50, 0x4B, 0x03, 0x04]) : Data("%PDF-".utf8) }
    }

    enum Provider: String {
        case gutenberg, brasiliana, camara

        var label: String { L10n.string("discovery.provider.\(rawValue)") }
        var rights: String { L10n.string("discovery.rights.\(rawValue)") }

        var filenameLabel: String {
            switch self {
            case .gutenberg: return "Gutenberg"
            case .brasiliana: return "BBM-USP"
            case .camara: return "Camara"
            }
        }

        func acceptsDownload(from url: URL) -> Bool {
            guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else {
                return false
            }
            switch self {
            case .gutenberg: return ["gutenberg.org", "www.gutenberg.org"].contains(url.host ?? "")
            case .brasiliana: return url.host == "digital.bbm.usp.br"
            case .camara: return false // Validated against the exact curated file below.
            }
        }
    }

    struct Edition: Identifiable {
        struct ID: Hashable {
            let provider: Provider
            let number: Int
        }

        let id: ID
        let title: String
        let authors: [String]
        let languages: [String]
        let files: [(format: Format, url: URL)]
        let source: URL

        var attribution: String { "\(id.provider.label) · \(id.provider.rights)" }

        var detail: String {
            let languageNames = languages.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            return [authors.joined(separator: ", "), languageNames.joined(separator: ", "),
                    files.map { $0.format.rawValue.uppercased() }.joined(separator: " / ")]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    struct Page {
        let editions: [Edition]
        let hasMore: Bool
        let gutenbergUnavailable: Bool
    }

    private struct Response: Decodable {
        let next: String?
        let results: [Record]
    }

    private struct Record: Decodable {
        struct Author: Decodable { let name: String }
        let id: Int
        let title: String
        let authors: [Author]
        let languages: [String]
        let copyright: Bool?
        let formats: [String: String]

        var edition: Edition? {
            guard copyright == false, id > 0, !title.isEmpty else { return nil }
            let files: [(format: Format, url: URL)] = Format.allCases.compactMap { format in
                guard let value = formats[format.mediaType], let url = URL(string: value),
                      Provider.gutenberg.acceptsDownload(from: url) else { return nil }
                return (format, url)
            }
            guard !files.isEmpty else { return nil }
            return Edition(id: Edition.ID(provider: .gutenberg, number: id), title: title,
                           authors: authors.map(\.name), languages: languages, files: files,
                           source: gutenbergSource(for: id))
        }
    }

    private enum Failure: Error { case response, file }

    static let brazilianCatalog = URL(string: "https://meclivros.mec.gov.br/search")!
    // The publisher offers free downloads of this edition with its own editorial material.
    private static let camaraEdition = Edition(
        id: Edition.ID(provider: .camara, number: 28739), title: "Dom Casmurro",
        authors: ["Machado de Assis"], languages: ["pt"],
        files: [
            (.epub, URL(string: "https://bd-rest.camara.leg.br/server/api/core/bitstreams/2b30f5a5-5e5f-49fd-9db7-f4a6c31c457f/content")!),
            (.pdf, URL(string: "https://bd-rest.camara.leg.br/server/api/core/bitstreams/8835c1ee-9566-4465-bc91-ce7003a6d4de/content")!),
        ],
        source: URL(string: "https://livraria.camara.leg.br/produto/dom-casmurro/")!)
    // The official BBM/USP record marks this 1899 first edition as public domain.
    private static let brazilianEditions = [
        Edition(id: Edition.ID(provider: .brasiliana, number: 4828), title: "Dom Casmurro",
                authors: ["Machado de Assis"], languages: ["pt"],
                files: [(.pdf, URL(string: "https://digital.bbm.usp.br/bitstream/bbm/4828/1/002038_COMPLETO.pdf")!)],
                source: URL(string: "https://digital.bbm.usp.br/handle/bbm/4828")!),
        camaraEdition,
    ]
    private static let searchEndpoint = URL(string: "https://gutendex.com/books/")!

    // Each EPUB's metadata identifies the edition and its public-domain status in the US.
    private static let reviewedGutenbergEditions = [
        reviewedEdition(57001, title: "Papeis Avulsos", author: "Machado de Assis", language: "pt",
                        epub: "https://gutenberg.pglaf.org/cache/epub/57001/pg57001-images-3.epub"),
        reviewedEdition(11, title: "Alice's Adventures in Wonderland", author: "Lewis Carroll", language: "en",
                        epub: "https://gutenberg.pglaf.org/cache/epub/11/pg11-images-3.epub"),
        reviewedEdition(1342, title: "Pride and Prejudice", author: "Jane Austen", language: "en",
                        epub: "https://gutenberg.pglaf.org/cache/epub/1342/pg1342.epub"),
        reviewedEdition(76, title: "Adventures of Huckleberry Finn", author: "Mark Twain", language: "en",
                        epub: "https://gutenberg.pglaf.org/cache/epub/76/pg76.epub"),
    ]

    private static func gutenbergSource(for number: Int) -> URL {
        URL(string: "https://www.gutenberg.org/ebooks/\(number)")!
    }

    private static func reviewedEdition(_ number: Int, title: String, author: String, language: String,
                                        epub: String) -> Edition {
        Edition(id: Edition.ID(provider: .gutenberg, number: number), title: title,
                authors: [author], languages: [language], files: [(.epub, URL(string: epub)!)],
                source: gutenbergSource(for: number))
    }

    private typealias DownloadDestination = @Sendable (URL) -> Bool

    private struct DownloadLocation {
        let url: URL
        let format: Format
        let acceptsDestination: DownloadDestination

        static func exact(_ url: URL, format: Format) -> DownloadLocation {
            DownloadLocation(url: url, format: format, acceptsDestination: {
                $0.absoluteString == url.absoluteString
            })
        }
    }

    private let searchData: (URLRequest) async throws -> (Data, URLResponse)
    private let downloadFile: (DownloadLocation, Provider) async throws -> (URL, URLResponse)

    init(session: URLSession = .shared,
         searchData: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         downloadFile: ((URLRequest, Provider) async throws -> (URL, URLResponse))? = nil) {
        self.searchData = searchData ?? { try await session.data(for: $0) }
        self.downloadFile = { location, provider in
            let request = URLRequest(url: location.url, timeoutInterval: 30)
            if let downloadFile { return try await downloadFile(request, provider) }
            let redirects = DownloadRedirects(acceptsDestination: location.acceptsDestination)
            return try await session.download(for: request, delegate: redirects)
        }
    }

    static func searchURL(query: String, language: Language, page: Int) -> URL {
        var components = URLComponents(url: searchEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "copyright", value: "false"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        if language != .all {
            components.queryItems?.append(URLQueryItem(name: "languages", value: language.rawValue))
        }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    static func decode(_ data: Data) throws -> Page {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return Page(editions: response.results.compactMap(\.edition),
                    hasMore: response.next != nil, gutenbergUnavailable: false)
    }

    func search(query: String, language: Language, page: Int) async throws -> Page {
        let localEditions = page == 1
            ? Self.matches(Self.brazilianEditions, query: query, language: language) : []
        do {
            let request = URLRequest(url: Self.searchURL(query: query, language: language, page: page),
                                     timeoutInterval: 20)
            let (data, response) = try await searchData(request)
            try Task.checkCancellation()
            guard Self.success(response), let url = response.url,
                  url.scheme == "https", url.host == Self.searchEndpoint.host else { throw Failure.response }
            let result = try Self.decode(data)
            return Page(editions: localEditions + result.editions, hasMore: result.hasMore, gutenbergUnavailable: false)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            guard page == 1 else { throw error }
            let reviewedMatches = Self.matches(Self.reviewedGutenbergEditions, query: query, language: language)
            let fallback = localEditions + reviewedMatches
            guard !fallback.isEmpty else { throw error }
            return Page(editions: fallback, hasMore: false, gutenbergUnavailable: true)
        }
    }

    private static func matches(_ editions: [Edition], query: String, language: Language) -> [Edition] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return [] }
        return editions.filter { edition in
            guard language == .all || edition.languages.contains(language.rawValue) else { return false }
            let searchable = ([edition.title] + edition.authors).joined(separator: " ")
            return terms.allSatisfy {
                searchable.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    private static func downloadLocations(for edition: Edition) -> [DownloadLocation] {
        let provider = edition.id.provider
        if provider == .camara {
            guard edition.id == camaraEdition.id else { return [] }
            return camaraEdition.files.compactMap { file in
                let location = DownloadLocation.exact(file.url, format: file.format)
                guard edition.files.contains(where: {
                    $0.format == file.format && location.acceptsDestination($0.url)
                }) else { return nil }
                return location
            }
        }
        let reviewedEdition = reviewedGutenbergEditions.first { $0.id == edition.id }
        return edition.files.flatMap { file -> [DownloadLocation] in
            let original = DownloadLocation(url: file.url, format: file.format, acceptsDestination: {
                provider.acceptsDownload(from: $0)
            })
            let isTrustedOriginal = original.acceptsDestination(file.url)
            guard file.format == .epub, let mirror = reviewedEdition?.files.first?.url else {
                return isTrustedOriginal ? [original] : []
            }
            let mirrorLocation = DownloadLocation.exact(mirror, format: .epub)
            if mirrorLocation.acceptsDestination(file.url) { return [mirrorLocation] }
            return isTrustedOriginal ? [mirrorLocation, original] : []
        }
    }

    func download(_ edition: Edition) async throws -> URL {
        try Task.checkCancellation()
        for location in Self.downloadLocations(for: edition) {
            try Task.checkCancellation()
            do {
                let (temporaryFile, response) = try await downloadFile(location, edition.id.provider)
                defer { try? FileManager.default.removeItem(at: temporaryFile) }
                try Task.checkCancellation()
                guard Self.success(response), let url = response.url, location.acceptsDestination(url) else {
                    throw Failure.response
                }
                return try Self.stage(temporaryFile, edition: edition, format: location.format)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            }
        }
        throw Failure.file
    }

    private static func stage(_ file: URL, edition: Edition, format: Format) throws -> URL {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.read(upToCount: format.signature.count) == format.signature else { throw Failure.file }
        if format == .epub {
            guard ZipReader.listEntries(in: file)?.contains("META-INF/container.xml") == true else {
                throw Failure.file
            }
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let title = edition.title.components(separatedBy: CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: "/\\:"))).joined(separator: " ")
        let truncatedTitle = String(decoding: title.utf8.prefix(120), as: UTF8.self)
        let provider = edition.id.provider.filenameLabel
        let filename = "\(truncatedTitle) - \(provider) \(edition.id.number)"
        let url = directory.appendingPathComponent(filename).appendingPathExtension(format.rawValue)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try manager.moveItem(at: file, to: url)
            return url
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private static func success(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(response.statusCode)
    }

    private final class DownloadRedirects: NSObject, URLSessionTaskDelegate {
        let acceptsDestination: DownloadDestination

        init(acceptsDestination: @escaping DownloadDestination) {
            self.acceptsDestination = acceptsDestination
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(acceptsDestination) == true ? request : nil)
        }
    }
}
