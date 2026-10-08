import Foundation
import Darwin

private typealias ConverterSessionOpen = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
private typealias ConverterSessionMetadata = @convention(c) (UnsafeRawPointer?) -> UnsafeMutablePointer<CChar>?
private typealias ConverterSessionFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias ConverterChapterCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
private typealias ConverterSessionConvertJob = @convention(c) (
    UnsafeRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32,
    ConverterChapterCallback?, ConverterChapterCallback?, UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?
private typealias ConverterSessionConvertJobOptionsV1 = @convention(c) (
    UnsafeRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32,
    ConverterChapterCallback?, ConverterChapterCallback?, UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?
private typealias ConverterSessionConvert = @convention(c) (
    UnsafeRawPointer?, UnsafePointer<CChar>?, Int32, Int32
) -> UnsafeMutablePointer<CChar>?
private typealias ConverterStringFree = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
private typealias ConverterLastError = @convention(c) () -> UnsafeMutablePointer<CChar>?
private typealias ConverterOptionsValidateV1 = @convention(c) (UnsafePointer<CChar>?) -> Bool
private typealias ConverterTtsModels = @convention(c) () -> UnsafeMutablePointer<CChar>?
private typealias ConverterTtsDefaultEngine = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32) -> UnsafeMutablePointer<CChar>?
private typealias ConverterTtsInstalledReadyEngine = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
private typealias ConverterTtsModelInstall = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
private typealias ConverterTtsModelRemove = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Bool
private typealias ConverterTtsModelMetadata = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
private typealias ConverterTtsModelInstallManifest = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
private typealias ConverterTtsModelInstallCatalogManifest = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

/// Errors exposed by the optional embedded converter seam.
enum EmbeddedConverterError: Error, LocalizedError, Equatable {
    case artifactUnavailable
    case artifactInvalid(String)
    case conversionFailed(String)
    case optionsABIUnavailable

    var errorDescription: String? {
        switch self {
        case .artifactUnavailable: return "Embedded converter artifact is unavailable"
        case .artifactInvalid(let reason): return "Embedded converter artifact is invalid: \(reason)"
        case .conversionFailed(let reason): return "Embedded conversion failed: \(reason)"
        case .optionsABIUnavailable:
            return "Explicit conversion options require converter_session_convert_job_options_json_v1; rebuild and embed a compatible Rust converter."
        }
    }
}

private final class ChapterCallbackBox: @unchecked Sendable {
    let progressHandler: (@Sendable (Data) -> Void)?
    let chapterHandler: (@Sendable (Data) -> Void)?

    init(
        progressHandler: (@Sendable (Data) -> Void)?,
        chapterHandler: (@Sendable (Data) -> Void)?
    ) {
        self.progressHandler = progressHandler
        self.chapterHandler = chapterHandler
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
    private let ttsInstalledReadyEngine: ((UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?)?
    private let ttsModelInstall: ((UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?)?
    private let ttsModelRemove: ((UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Bool)?
    private let ttsModelMetadata: ((UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?)?
    private let ttsModelInstallManifest: ((UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?)?
    private let ttsModelInstallCatalogManifest: ((UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?)?
    private var _open: ConverterSessionOpen = { _ in nil }
    private var convertJobJSON: ConverterSessionConvertJob?
    private var convertJSON: ConverterSessionConvert?
    private var convertJobOptionsJSON: ConverterSessionConvertJobOptionsV1? = nil
    private var validateOptionsJSON: ConverterOptionsValidateV1? = nil
    private var loadError: String?

    private static let progressCallback: ConverterChapterCallback = { eventJSON, context in
        guard let eventJSON, let context else { return }
        let box = Unmanaged<ChapterCallbackBox>
            .fromOpaque(context)
            .takeUnretainedValue()
        box.progressHandler?(Data(String(cString: eventJSON).utf8))
    }

    private static let chapterCallback: ConverterChapterCallback = { eventJSON, context in
        guard let eventJSON, let context else { return }
        let box = Unmanaged<ChapterCallbackBox>
            .fromOpaque(context)
            .takeUnretainedValue()
        box.chapterHandler?(Data(String(cString: eventJSON).utf8))
    }

    init(bundle: Bundle = .main, libraryURL overrideURL: URL? = nil) {
        let productsAppFramework = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3.app/Contents/Frameworks/libconverter_ffi.dylib")
        let parentBundle = Bundle(url: bundle.bundleURL.deletingLastPathComponent())
        let appBundle = Bundle(url: bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent())
        let bundles = [bundle, parentBundle, appBundle].compactMap { $0 }
        let configuredPath = ProcessInfo.processInfo.environment["EPUB2MP3_CONVERTER_FFI_DYLIB"]
        let configuredURL = configuredPath.flatMap { path -> URL? in
            guard !path.contains("${"), FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        let url = overrideURL ?? configuredURL ?? ([productsAppFramework] + bundles.flatMap { candidate -> [URL] in
            let frameworkURLs = [
                candidate.bundleURL.appendingPathComponent("Frameworks/libconverter_ffi.dylib"),
                candidate.bundleURL.appendingPathComponent("Frameworks/converter_ffi.dylib"),
            ]
            return frameworkURLs + [
                candidate.url(forResource: "converter_ffi", withExtension: "dylib"),
                candidate.url(forResource: "libconverter_ffi", withExtension: "dylib"),
            ].compactMap { $0 }
        }).first(where: { FileManager.default.fileExists(atPath: $0.path) })
        guard let url,
              let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            let error = dlerror()
            loadError = error.map { String(cString: $0) } ?? "dylib path not found"
            handle = nil; close = { _ in }; metadata = { _ in nil }; freeString = { _ in }; lastError = { nil }; ttsModelsJSON = { nil }; ttsDefaultEngine = { _, _, _ in nil }; ttsInstalledReadyEngine = nil; ttsModelInstall = nil; ttsModelRemove = nil; ttsModelMetadata = nil; ttsModelInstallManifest = nil; ttsModelInstallCatalogManifest = nil; return
        }
        func symbol<T>(_ name: String, as: T.Type) -> T? { dlsym(library, name).map { unsafeBitCast($0, to: T.self) } }
        guard let open: ConverterSessionOpen = symbol("converter_session_open", as: ConverterSessionOpen.self),
              let meta: ConverterSessionMetadata = symbol("converter_session_metadata_json", as: ConverterSessionMetadata.self),
              let dispose: ConverterSessionFree = symbol("converter_session_free", as: ConverterSessionFree.self),
              let free: ConverterStringFree = symbol("converter_string_free", as: ConverterStringFree.self),
              let error: ConverterLastError = symbol("converter_last_error", as: ConverterLastError.self),
              let models: ConverterTtsModels = symbol("converter_tts_models_json", as: ConverterTtsModels.self),
              let defaultEngine: ConverterTtsDefaultEngine = symbol("converter_tts_default_engine", as: ConverterTtsDefaultEngine.self) else {
            loadError = "dylib missing one or more required ABI symbols"
            dlclose(library); handle = nil; close = { _ in }; metadata = { _ in nil }; freeString = { _ in }; lastError = { nil }; ttsModelsJSON = { nil }; ttsDefaultEngine = { _, _, _ in nil }; ttsInstalledReadyEngine = nil; ttsModelInstall = nil; ttsModelRemove = nil; ttsModelMetadata = nil; ttsModelInstallManifest = nil; ttsModelInstallCatalogManifest = nil; return
        }
        handle = library
        close = { value in dispose(value) }
        metadata = { value in meta(value) }
        freeString = free
        lastError = error
        ttsModelsJSON = { models() }
        ttsDefaultEngine = { language, platform, api in defaultEngine(language, platform, api) }
        ttsInstalledReadyEngine = symbol("converter_tts_installed_ready_engine", as: ConverterTtsInstalledReadyEngine.self)
        ttsModelInstall = symbol("converter_tts_model_install", as: ConverterTtsModelInstall.self)
        ttsModelRemove = symbol("converter_tts_model_remove", as: ConverterTtsModelRemove.self)
        ttsModelMetadata = symbol("converter_tts_model_metadata", as: ConverterTtsModelMetadata.self)
        ttsModelInstallManifest = symbol("converter_tts_model_install_manifest", as: ConverterTtsModelInstallManifest.self)
        ttsModelInstallCatalogManifest = symbol("converter_tts_model_install_catalog_manifest", as: ConverterTtsModelInstallCatalogManifest.self)
        _open = open
        convertJobJSON = symbol("converter_session_convert_job_json", as: ConverterSessionConvertJob.self)
        convertJSON = symbol("converter_session_convert_json", as: ConverterSessionConvert.self)
        convertJobOptionsJSON = symbol("converter_session_convert_job_options_json_v1", as: ConverterSessionConvertJobOptionsV1.self)
        validateOptionsJSON = symbol("converter_conversion_options_validate_json_v1", as: ConverterOptionsValidateV1.self)
    }

    convenience init(libraryURL: URL) {
        self.init(bundle: .main, libraryURL: libraryURL)
    }

    func openBook(at url: URL) throws -> EmbeddedBook {
        guard handle != nil else {
            throw EmbeddedConverterError.artifactInvalid("Converter dylib could not be loaded: \(loadError ?? "unknown dlopen error")")
        }
        guard let session = _open(url.path) else { throw EmbeddedConverterError.conversionFailed(readError()) }
        defer { close(session) }
        guard let value = metadata(session), let json = String(validatingUTF8: value) else { throw EmbeddedConverterError.conversionFailed(readError()) }
        freeString(value)
        return EmbeddedBook(metadataJSON: Data(json.utf8))
    }

    /// Converts an EPUB through the bundled Rust ABI and returns its manifest.
    /// Chapter bounds are inclusive; (-1, -1) means all, and (start, -1) means to the end.
    func convertBook(
        at url: URL,
        outputDirectory: URL,
        jobID: String,
        chapterStart: Int32 = -1,
        chapterEnd: Int32 = -1,
        options: ConversionOptions? = nil,
        onProgress: (@Sendable (Data) -> Void)? = nil,
        onChapterCompleted: (@Sendable (Data) -> Void)? = nil
    ) throws -> Data {
        try validateConversionSupport(options: options)
        let optionsJSON = try options?.encodedJSON()
        guard let session = _open(url.path) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { close(session) }
        let result: UnsafeMutablePointer<CChar>?
        if optionsJSON != nil || convertJobJSON != nil {
            let callbackBox: ChapterCallbackBox? = (onProgress != nil || onChapterCompleted != nil)
                ? ChapterCallbackBox(progressHandler: onProgress, chapterHandler: onChapterCompleted)
                : nil
            let context = callbackBox.map { Unmanaged.passRetained($0).toOpaque() }
            defer {
                if let context {
                    Unmanaged<ChapterCallbackBox>.fromOpaque(context).release()
                }
            }
            result = try outputDirectory.path.withCString { outputPointer in
                try jobID.withCString { jobPointer in
                    if let optionsJSON {
                        guard let convertJobOptionsJSON else {
                            throw EmbeddedConverterError.optionsABIUnavailable
                        }
                        return optionsJSON.withCString { optionsPointer in
                            convertJobOptionsJSON(
                                session, outputPointer, jobPointer, optionsPointer,
                                chapterStart, chapterEnd,
                                onProgress == nil ? nil : Self.progressCallback,
                                onChapterCompleted == nil ? nil : Self.chapterCallback,
                                context
                            )
                        }
                    }
                    guard let convertJobJSON else {
                        throw EmbeddedConverterError.artifactInvalid("Loaded converter library lacks the callback conversion symbol.")
                    }
                    return convertJobJSON(
                        session, outputPointer, jobPointer, chapterStart, chapterEnd,
                        onProgress == nil ? nil : Self.progressCallback,
                        onChapterCompleted == nil ? nil : Self.chapterCallback,
                        context
                    )
                }
            }
        } else {
            guard onProgress == nil, onChapterCompleted == nil, let convertJSON else {
                throw EmbeddedConverterError.artifactInvalid(
                    "Loaded converter library lacks the callback conversion symbol."
                )
            }
            result = outputDirectory.path.withCString { outputPointer in
                convertJSON(session, outputPointer, chapterStart, chapterEnd)
            }
        }
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let json = String(validatingUTF8: value) else {
            throw EmbeddedConverterError.conversionFailed("Rust returned invalid UTF-8 manifest JSON.")
        }
        return Data(json.utf8)
    }

    /// Capability check before book access or output reservation; never discard explicit options.
    func validateConversionSupport(options: ConversionOptions? = nil) throws {
        if let options {
            guard handle != nil, convertJobOptionsJSON != nil, let validateOptionsJSON else {
                throw EmbeddedConverterError.optionsABIUnavailable
            }
            let json = try options.encodedJSON()
            guard json.withCString({ validateOptionsJSON($0) }) else {
                throw EmbeddedConverterError.conversionFailed(readError())
            }
            return
        }
        guard handle != nil, convertJobJSON != nil || convertJSON != nil else {
            throw EmbeddedConverterError.artifactInvalid(
                "Loaded converter library lacks conversion symbols (job: \(convertJobJSON != nil), legacy: \(convertJSON != nil))."
            )
        }
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

    func ttsInstalledReadyEngine(language: String, platform: String, installedModelIDsJSON: String, readyModelIDsJSON: String, androidAPI: UInt32 = 0) throws -> String {
        guard handle != nil, let select = ttsInstalledReadyEngine else { throw EmbeddedConverterError.artifactUnavailable }
        let result = language.withCString { languagePointer in
            platform.withCString { platformPointer in
                installedModelIDsJSON.withCString { installedPointer in
                    readyModelIDsJSON.withCString { readyPointer in
                        select(languagePointer, platformPointer, androidAPI, installedPointer, readyPointer)
                    }
                }
            }
        }
        guard let value = result, let engine = String(validatingUTF8: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        return engine
    }

    func installTtsModel(modelID: String, url: String, sha256: String, root: String) throws -> URL {
        guard handle != nil, let install = ttsModelInstall else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            url.withCString { urlPointer in
                sha256.withCString { hashPointer in
                    root.withCString { rootPointer in
                        install(modelPointer, urlPointer, hashPointer, rootPointer)
                    }
                }
            }
        }
        guard let value = result, let path = String(validatingUTF8: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        return URL(fileURLWithPath: path)
    }

    func installTtsModelManifest(modelID: String, artifactsJSON: String, root: String) throws -> URL {
        guard handle != nil, let install = ttsModelInstallManifest else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            artifactsJSON.withCString { artifactsPointer in
                root.withCString { rootPointer in
                    install(modelPointer, artifactsPointer, rootPointer)
                }
            }
        }
        guard let value = result, let path = String(validatingUTF8: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        return URL(fileURLWithPath: path)
    }

    func installTtsModelFromCatalog(modelID: String, root: String) throws -> URL {
        guard handle != nil, let install = ttsModelInstallCatalogManifest else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            root.withCString { rootPointer in
                install(modelPointer, rootPointer)
            }
        }
        guard let value = result, let path = String(validatingUTF8: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        return URL(fileURLWithPath: path)
    }

    func removeTtsModel(modelID: String, root: String) throws {
        guard handle != nil, let remove = ttsModelRemove else { throw EmbeddedConverterError.artifactUnavailable }
        let removed = modelID.withCString { modelPointer in
            root.withCString { rootPointer in
                remove(modelPointer, rootPointer)
            }
        }
        guard removed else { throw EmbeddedConverterError.conversionFailed(readError()) }
    }

    func ttsModelMetadata(modelID: String, root: String) throws -> Data? {
        guard handle != nil, let metadata = ttsModelMetadata else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            root.withCString { rootPointer in metadata(modelPointer, rootPointer) }
        }
        guard let value = result else { return nil }
        guard let json = String(validatingUTF8: value) else { throw EmbeddedConverterError.conversionFailed(readError()) }
        defer { freeString(value) }
        return Data(json.utf8)
    }

    private func readError() -> String {
        guard let value = lastError(), let text = String(validatingUTF8: value) else { return "unknown converter-ffi error" }
        freeString(value)
        return text
    }
}
