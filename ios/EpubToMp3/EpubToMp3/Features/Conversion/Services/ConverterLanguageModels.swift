import Foundation

/// The three pure language/model exports of the Rust FFI. Strings returned by the
/// library are owned by the caller and always freed here.
struct ConverterLanguageModels {
    var catalogLanguagesJSON: ConverterTtsCatalogLanguagesV1?
    var resolveJSON: ConverterTtsResolveLanguageModelV1?
    var bookLanguageJSON: ConverterBookLanguageV1?
    var narrationPlanJSON: ConverterBookNarrationPlanV1?
    var freeString: ConverterStringFree = { _ in }
    var lastError: ConverterLastError = { nil }

    func catalogLanguages(platform: String, androidAPI: UInt32 = 0) throws -> [CatalogLanguage] {
        guard let read = catalogLanguagesJSON else { throw EmbeddedConverterError.artifactUnavailable }
        let data = try owned(platform.withCString { read($0, androidAPI) })
        struct Response: Decodable { let languages: [CatalogLanguage] }
        return try JSONDecoder().decode(Response.self, from: data).languages
    }

    func resolve(_ request: LanguageModelResolutionRequest) throws -> LanguageModelResolution {
        guard let resolve = resolveJSON else { throw EmbeddedConverterError.artifactUnavailable }
        let body = try JSONEncoder().encode(request)
        let data = try body.withUnsafeBytes { raw -> Data in
            let text = String(decoding: raw, as: UTF8.self)
            return try owned(text.withCString { resolve($0) })
        }
        return try JSONDecoder().decode(LanguageModelResolution.self, from: data)
    }

    /// Blocking: parses and samples the whole book. Call off the main actor.
    func bookLanguage(at url: URL) throws -> BookLanguageAnalysis {
        guard let read = bookLanguageJSON else { throw EmbeddedConverterError.artifactUnavailable }
        let data = try owned(url.path.withCString { read($0) })
        return try JSONDecoder().decode(BookLanguageAnalysis.self, from: data)
    }

    /// The narration plan of one book, from Rust's own book-language answer. Pure; never downloads.
    func narrationPlan(bookLanguageJSON: Data, inputs: NarrationPlanInputs) throws -> NarrationPlan {
        guard let plan = narrationPlanJSON else { throw EmbeddedConverterError.artifactUnavailable }
        let text = String(decoding: try inputs.requestBody(bookLanguageJSON: bookLanguageJSON), as: UTF8.self)
        let data = try owned(text.withCString { plan($0) })
        return try JSONDecoder().decode(NarrationPlan.self, from: data)
    }

    private func owned(_ result: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let value = result else {
            let message = lastError().map { pointer -> String in
                defer { freeString(pointer) }
                return String(validatingCString: pointer) ?? "unknown converter-ffi error"
            } ?? "unknown converter-ffi error"
            throw EmbeddedConverterError.conversionFailed(message)
        }
        defer { freeString(value) }
        guard let json = String(validatingCString: value) else {
            throw EmbeddedConverterError.artifactInvalid("Language model JSON contains invalid UTF-8")
        }
        return Data(json.utf8)
    }
}
