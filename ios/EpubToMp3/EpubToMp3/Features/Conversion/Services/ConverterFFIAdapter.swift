import Foundation
import Darwin

private typealias ConverterSessionOpen = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
private typealias ConverterSessionMetadata = @convention(c) (UnsafeRawPointer?) -> UnsafeMutablePointer<CChar>?
private typealias ConverterSessionFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias ConverterStringFree = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
private typealias ConverterLastError = @convention(c) () -> UnsafeMutablePointer<CChar>?

private let converterSessionOpenSignature: ConverterSessionOpen = { _ in nil }
private let converterSessionMetadataSignature: ConverterSessionMetadata = { _ in nil }
private let converterSessionFreeSignature: ConverterSessionFree = { _ in }
private let converterStringFreeSignature: ConverterStringFree = { _ in }
private let converterLastErrorSignature: ConverterLastError = { nil }

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
    private let handle: UnsafeMutableRawPointer?
    private let close: (UnsafeMutableRawPointer?) -> Void
    private let metadata: (UnsafeRawPointer?) -> UnsafeMutablePointer<CChar>?
    private let freeString: (UnsafeMutablePointer<CChar>?) -> Void
    private let lastError: () -> UnsafeMutablePointer<CChar>?

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "converter_ffi", withExtension: "dylib"),
              let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            handle = nil; close = { _ in }; metadata = { _ in nil }; freeString = { _ in }; lastError = { nil }; return
        }
        handle = library
        func symbol<T>(_ name: String, as: T.Type) -> T? { dlsym(library, name).map { unsafeBitCast($0, to: T.self) } }
        guard let open: ConverterSessionOpen = symbol("converter_session_open", as: ConverterSessionOpen.self),
              let meta: ConverterSessionMetadata = symbol("converter_session_metadata_json", as: ConverterSessionMetadata.self),
              let dispose: ConverterSessionFree = symbol("converter_session_free", as: ConverterSessionFree.self),
              let free: ConverterStringFree = symbol("converter_string_free", as: ConverterStringFree.self),
              let error: ConverterLastError = symbol("converter_last_error", as: ConverterLastError.self) else {
            dlclose(library); handle = nil; close = { _ in }; metadata = { _ in nil }; freeString = { _ in }; lastError = { nil }; return
        }
        handle = library; close = { value in dispose(value) }; metadata = { value in meta(value) }; freeString = free; lastError = error
        _open = open
    }

    private var _open: ConverterSessionOpen = { _ in nil }

    func openBook(at url: URL) throws -> EmbeddedBook {
        guard handle != nil else { throw EmbeddedConverterError.artifactUnavailable }
        guard let session = _open(url.path) else { throw EmbeddedConverterError.conversionFailed(readError()) }
        defer { close(session) }
        guard let value = metadata(session), let json = String(validatingUTF8: value) else { throw EmbeddedConverterError.conversionFailed(readError()) }
        freeString(value)
        return EmbeddedBook(metadataJSON: Data(json.utf8))
    }

    private func readError() -> String { guard let value = lastError(), let text = String(validatingUTF8: value) else { return "unknown converter-ffi error" }; freeString(value); return text }
}
