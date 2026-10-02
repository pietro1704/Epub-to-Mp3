import Foundation
import Darwin

private typealias ConverterSessionOpen = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
private typealias ConverterSessionMetadata = @convention(c) (UnsafeRawPointer?) -> UnsafeMutablePointer<CChar>?
private typealias ConverterSessionFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias ConverterStringFree = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
private typealias ConverterLastError = @convention(c) () -> UnsafeMutablePointer<CChar>?
private typealias ConverterTtsModels = @convention(c) () -> UnsafeMutablePointer<CChar>?
private typealias ConverterTtsDefaultEngine = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32) -> UnsafeMutablePointer<CChar>?

/// Errors exposed by the optional embedded converter seam.
enum EmbeddedConverterError: Error, LocalizedError, Equatable {
    case artifactUnavailable
    case artifactInvalid(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .artifactUnavailable: return "Embedded converter artifact is unavailable"
        case .artifactInvalid(let reason): return "Embedded converter artifact is invalid: \(reason)"
        case .conversionFailed(let reason): return "Embedded conversion failed: \(reason)"
        }
    }
}

protocol EmbeddedConverter { func openBook(at url: URL) throws -> EmbeddedBook }
struct EmbeddedBook { let metadataJSON: Data }

/// Loads and invokes the stable C ABI only when the bundled dylib is present.
final class ConverterFFIAdapter: EmbeddedConverter {
    private var handle: UnsafeMutableRawPointer?
    private let close: (UnsafeMutableRawPointer?) -> Void
    private let metadata: (UnsafeRawPointer?) -> UnsafeMutablePointer<CChar>?
    private let freeString: (UnsafeMutablePointer<CChar>?) -> Void
    private let lastError: () -> UnsafeMutablePointer<CChar>?
    private let ttsModelsJSON: () -> UnsafeMutablePointer<CChar>?
    private let ttsDefaultEngine: (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private var _open: ConverterSessionOpen = { _ in nil }

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "converter_ffi", withExtension: "dylib"),
              let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            handle = nil; close = { _ in }; metadata = { _ in nil }; freeString = { _ in }; lastError = { nil }; ttsModelsJSON = { nil }; ttsDefaultEngine = { _, _, _ in nil }; return
        }
        func symbol<T>(_ name: String, as: T.Type) -> T? { dlsym(library, name).map { unsafeBitCast($0, to: T.self) } }
        guard let open: ConverterSessionOpen = symbol("converter_session_open", as: ConverterSessionOpen.self),
              let meta: ConverterSessionMetadata = symbol("converter_session_metadata_json", as: ConverterSessionMetadata.self),
              let dispose: ConverterSessionFree = symbol("converter_session_free", as: ConverterSessionFree.self),
              let free: ConverterStringFree = symbol("converter_string_free", as: ConverterStringFree.self),
              let error: ConverterLastError = symbol("converter_last_error", as: ConverterLastError.self),
              let models: ConverterTtsModels = symbol("converter_tts_models_json", as: ConverterTtsModels.self),
              let defaultEngine: ConverterTtsDefaultEngine = symbol("converter_tts_default_engine", as: ConverterTtsDefaultEngine.self) else {
            dlclose(library); handle = nil; close = { _ in }; metadata = { _ in nil }; freeString = { _ in }; lastError = { nil }; ttsModelsJSON = { nil }; ttsDefaultEngine = { _, _, _ in nil }; return
        }
        handle = library
        close = { value in dispose(value) }
        metadata = { value in meta(value) }
        freeString = free
        lastError = error
        ttsModelsJSON = { models() }
        ttsDefaultEngine = { language, platform, api in defaultEngine(language, platform, api) }
        _open = open
    }

    func openBook(at url: URL) throws -> EmbeddedBook {
        guard handle != nil else { throw EmbeddedConverterError.artifactUnavailable }
        guard let session = _open(url.path) else { throw EmbeddedConverterError.conversionFailed(readError()) }
        defer { close(session) }
        guard let value = metadata(session), let json = String(validatingUTF8: value) else { throw EmbeddedConverterError.conversionFailed(readError()) }
        freeString(value)
        return EmbeddedBook(metadataJSON: Data(json.utf8))
    }

    func ttsModels() throws -> Data {
        guard handle != nil, let value = ttsModelsJSON(), let json = String(validatingUTF8: value) else {
            throw EmbeddedConverterError.artifactUnavailable
        }
        defer { freeString(value) }
        return Data(json.utf8)
    }

    func ttsDefaultEngine(language: String, platform: String, androidAPI: UInt32 = 0) throws -> String {
        guard handle != nil else { throw EmbeddedConverterError.artifactUnavailable }
        let result = language.withCString { languagePointer in
            platform.withCString { platformPointer in
                ttsDefaultEngine(languagePointer, platformPointer, androidAPI)
            }
        }
        guard let value = result, let engine = String(validatingUTF8: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        return engine
    }

    private func readError() -> String {
        guard let value = lastError(), let text = String(validatingUTF8: value) else { return "unknown converter-ffi error" }
        freeString(value)
        return text
    }
}
