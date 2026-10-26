import Foundation
import Darwin

protocol EmbeddedConverter { func openBook(at url: URL) throws -> EmbeddedBook }
struct EmbeddedBook { let metadataJSON: Data }

/// Loads and invokes the stable C ABI only when the bundled dylib is present.
final class ConverterFFIAdapter: EmbeddedConverter {
    private var setPlatformTts: ConverterSetPlatformTts?
    private var auditionVoice: ConverterVoiceAudition?
    private var handle: UnsafeMutableRawPointer?
    private let close: (UnsafeMutableRawPointer?) -> Void
    private let metadata: (UnsafeRawPointer?) -> UnsafeMutablePointer<CChar>?
    private let freeString: (UnsafeMutablePointer<CChar>?) -> Void
    private let lastError: () -> UnsafeMutablePointer<CChar>?
    private var modelCatalog = ConverterModelCatalog()
    private var _open: ConverterSessionOpen = { _ in nil }
    private var convertJobJSON: ConverterSessionConvertJob?
    private var convertJSON: ConverterSessionConvert?
    private var convertJobOptionsJSON: ConverterSessionConvertJobOptionsV1? = nil
    private var convertStreamingJobJSON: ConverterSessionConvertStreamingJob?
    private var convertStreamingJobOptionsJSON: ConverterSessionConvertStreamingJobOptionsV1?
    private var jobControlCreate: ConverterJobControlCreate?
    private var jobControlFree: ConverterJobControlFree?
    private var jobControlCancel: ConverterJobControlCancel?
    private var jobControlPrioritize: ConverterJobControlPrioritize?
    private var jobControlWindow: ConverterJobControlWindow?
    private var jobControlWindowContains: ConverterJobControlWindowContains?
    private var jobControlListeningPosition: ConverterJobControlJSON?
    private var jobControlPlaybackFeedback: ConverterJobControlJSON?
    private var jobControlListeningGeneration: ConverterJobControlGeneration?
    private var validateOptionsJSON: ConverterOptionsValidateV1? = nil
    private var validateSessionOptionsJSON: ConverterOptionsValidateV1? = nil
    private var loadError: String?

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
            handle = nil; close = { _ in }; metadata = { _ in nil }; freeString = { _ in }; lastError = { nil }; return
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
            dlclose(library); handle = nil; close = { _ in }; metadata = { _ in nil }; freeString = { _ in }; lastError = { nil }; return
        }
        handle = library
        close = { value in dispose(value) }
        metadata = { value in meta(value) }
        freeString = free
        lastError = error
        modelCatalog = ConverterModelCatalog(
            available: true, freeString: free, lastError: error, modelsJSON: models,
            catalogJSON: symbol("converter_tts_catalog_json_v2", as: ConverterTtsModels.self),
            catalogJSONV3: symbol("converter_tts_catalog_json_v3", as: ConverterTtsCatalogV3.self),
            catalogProbeJSONV3: symbol("converter_tts_catalog_probe_json_v3", as: ConverterTtsCatalogProbeV3.self),
            defaultEngine: defaultEngine,
            selectInstalledReady: symbol("converter_tts_installed_ready_engine", as: ConverterTtsInstalledReadyEngine.self),
            installArtifact: symbol("converter_tts_model_install", as: ConverterTtsModelInstall.self),
            removeModel: symbol("converter_tts_model_remove", as: ConverterTtsModelRemove.self),
            modelMetadata: symbol("converter_tts_model_metadata", as: ConverterTtsModelMetadata.self),
            installManifest: symbol("converter_tts_model_install_manifest", as: ConverterTtsModelInstallManifest.self),
            installCatalogManifest: symbol("converter_tts_model_install_catalog_manifest", as: ConverterTtsModelInstallCatalogManifest.self),
            installOperationCreate: symbol("converter_tts_model_install_operation_create", as: ConverterModelInstallOperationCreate.self),
            installOperationRecover: symbol("converter_tts_model_install_operation_recover", as: ConverterModelInstallOperationRecover.self),
            installOperationPlan: symbol("converter_tts_model_install_operation_plan_json", as: ConverterModelInstallOperationJSON.self),
            installOperationEvent: symbol("converter_tts_model_install_operation_event_json", as: ConverterModelInstallOperationJSON.self),
            installOperationProgress: symbol("converter_tts_model_install_operation_record_progress", as: ConverterModelInstallOperationProgress.self),
            installOperationAccept: symbol("converter_tts_model_install_operation_accept_download", as: ConverterModelInstallOperationAccept.self),
            installOperationPublish: symbol("converter_tts_model_install_operation_publish", as: ConverterModelInstallOperationPublish.self),
            installOperationFail: symbol("converter_tts_model_install_operation_fail", as: ConverterModelInstallOperationFail.self),
            installOperationCancel: symbol("converter_tts_model_install_operation_cancel", as: ConverterModelInstallOperationCancel.self),
            installOperationFree: symbol("converter_tts_model_install_operation_free", as: ConverterModelInstallOperationFree.self)
        )
        setPlatformTts = symbol("converter_session_set_platform_tts_v1", as: ConverterSetPlatformTts.self)
        _open = open
        auditionVoice = symbol("converter_voice_audition_v1", as: ConverterVoiceAudition.self)
        convertJobJSON = symbol("converter_session_convert_job_json", as: ConverterSessionConvertJob.self)
        convertJSON = symbol("converter_session_convert_json", as: ConverterSessionConvert.self)
        convertJobOptionsJSON = symbol("converter_session_convert_job_options_json_v1", as: ConverterSessionConvertJobOptionsV1.self)
        convertStreamingJobJSON = symbol("converter_session_convert_streaming_job_json", as: ConverterSessionConvertStreamingJob.self)
        convertStreamingJobOptionsJSON = symbol("converter_session_convert_streaming_job_options_json_v1", as: ConverterSessionConvertStreamingJobOptionsV1.self)
        jobControlCreate = symbol("converter_job_control_create", as: ConverterJobControlCreate.self)
        jobControlFree = symbol("converter_job_control_free", as: ConverterJobControlFree.self)
        jobControlCancel = symbol("converter_job_control_cancel", as: ConverterJobControlCancel.self)
        jobControlPrioritize = symbol("converter_job_control_prioritize", as: ConverterJobControlPrioritize.self)
        jobControlWindow = symbol("converter_job_control_set_playback_window", as: ConverterJobControlWindow.self)
        jobControlWindowContains = symbol("converter_job_control_chapter_is_in_playback_window", as: ConverterJobControlWindowContains.self)
        jobControlListeningPosition = symbol("converter_job_control_set_listening_position_json_v2", as: ConverterJobControlJSON.self)
        jobControlPlaybackFeedback = symbol("converter_job_control_playback_feedback_json_v2", as: ConverterJobControlJSON.self)
        jobControlListeningGeneration = symbol("converter_job_control_listening_generation_v2", as: ConverterJobControlGeneration.self)
        validateOptionsJSON = symbol("converter_conversion_options_validate_json_v1", as: ConverterOptionsValidateV1.self)
        validateSessionOptionsJSON = symbol("converter_conversion_options_validate_json_v2", as: ConverterOptionsValidateV1.self)
    }

    convenience init(libraryURL: URL) {
        self.init(bundle: .main, libraryURL: libraryURL)
    }

    func audition(text: String, options: ConversionOptions, output: URL, control: ConverterPlaybackControl) throws {
        guard let auditionVoice else { throw EmbeddedConverterError.artifactInvalid("Voice audition ABI is unavailable") }
        let json = try options.encodedJSON()
        let accepted = json.withCString { optionsJSON in
            text.withCString { text in output.path.withCString { path in
                auditionVoice(optionsJSON, text, path, control.rawHandle)
            } }
        }
        guard accepted else {
            let error = lastError()
            defer { if let error { freeString(error) } }
            throw EmbeddedConverterError.conversionFailed(error.map { String(cString: $0) } ?? "Voice audition failed")
        }
    }

    func makePlaybackControl() throws -> ConverterPlaybackControl {
        guard let jobControlCreate, let jobControlFree, let jobControlCancel,
              let jobControlPrioritize, let jobControlWindow, let jobControlWindowContains,
              let rawHandle = jobControlCreate() else {
            throw EmbeddedConverterError.artifactInvalid("Loaded converter library lacks streaming control symbols.")
        }
        return ConverterPlaybackControl(
            rawHandle: rawHandle, free: jobControlFree,
            cancel: jobControlCancel, prioritize: jobControlPrioritize,
            setWindow: jobControlWindow,
            windowContains: jobControlWindowContains,
            listeningPosition: jobControlListeningPosition,
            playbackFeedback: jobControlPlaybackFeedback,
            listeningGeneration: jobControlListeningGeneration
        )
    }

    func openBook(at url: URL) throws -> EmbeddedBook {
        guard handle != nil else {
            throw EmbeddedConverterError.artifactInvalid("Converter dylib could not be loaded: \(loadError ?? "unknown dlopen error")")
        }
        guard let session = _open(url.path) else { throw EmbeddedConverterError.conversionFailed(readError()) }
        defer { close(session) }
        guard let value = metadata(session) else { throw EmbeddedConverterError.conversionFailed(readError()) }
        defer { freeString(value) }
        guard let json = String(validatingCString: value) else { throw EmbeddedConverterError.conversionFailed(readError()) }
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
        playbackControl: ConverterPlaybackControl? = nil,
        onProgress: (@Sendable (Data) -> Void)? = nil,
        onChapterCompleted: (@Sendable (Data) -> Void)? = nil,
        onAudioChunk: (@Sendable (Int, Int, Data) -> Bool)? = nil
    ) throws -> Data {
        try validateConversionSupport(options: options)
        let optionsJSON = try options?.encodedJSON()
        guard let session = _open(url.path) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { close(session) }
        let voiceReceipt = PlatformSpeechVoiceReceipt()
        let platformSpeech = PlatformSpeechSynthesizer(onVoiceUsed: { voiceReceipt.record($0) })
        defer { withExtendedLifetime(platformSpeech) {} }
        guard let setPlatformTts,
              setPlatformTts(session, ConverterCallbackBridge.platformTtsCallback,
                             Unmanaged.passUnretained(platformSpeech).toOpaque()) else {
            throw EmbeddedConverterError.artifactInvalid("Loaded converter library lacks platform speech ABI.")
        }
        let result: UnsafeMutablePointer<CChar>?
        if playbackControl != nil {
            guard let playbackControl,
                  optionsJSON == nil || convertStreamingJobOptionsJSON != nil,
                  let convertStreamingJobJSON else {
                throw EmbeddedConverterError.artifactInvalid("Loaded converter library lacks playback streaming ABI.")
            }
            let callbackBox = ConversionCallbackReceipt(
                voiceReceipt: voiceReceipt, progressHandler: onProgress, chapterHandler: onChapterCompleted,
                audioChunkHandler: onAudioChunk
            )
            let context = Unmanaged.passRetained(callbackBox).toOpaque()
            defer { Unmanaged<ConversionCallbackReceipt>.fromOpaque(context).release() }
            result = outputDirectory.path.withCString { outputPointer in
                jobID.withCString { jobPointer in
                    let progress = ConverterCallbackBridge.progressCallback
                    let chapter = onChapterCompleted == nil ? nil : ConverterCallbackBridge.chapterCallback
                    if let optionsJSON, let convertStreamingJobOptionsJSON {
                        return optionsJSON.withCString { optionsPointer in
                            convertStreamingJobOptionsJSON(
                                session, outputPointer, jobPointer, optionsPointer,
                                chapterStart, chapterEnd, progress, chapter,
                                onAudioChunk == nil ? nil : ConverterCallbackBridge.audioChunkCallback,
                                context, playbackControl.rawHandle
                            )
                        }
                    }
                    return convertStreamingJobJSON(
                        session, outputPointer, jobPointer, chapterStart, chapterEnd,
                        progress, chapter, onAudioChunk == nil ? nil : ConverterCallbackBridge.audioChunkCallback,
                        context, playbackControl.rawHandle
                    )
                }
            }
        } else if optionsJSON != nil || convertJobOptionsJSON != nil || convertJobJSON != nil {
            let callbackBox = ConversionCallbackReceipt(voiceReceipt: voiceReceipt, progressHandler: onProgress, chapterHandler: onChapterCompleted)
            let context = Unmanaged.passRetained(callbackBox).toOpaque()
            defer { Unmanaged<ConversionCallbackReceipt>.fromOpaque(context).release() }
            result = try outputDirectory.path.withCString { outputPointer in
                try jobID.withCString { jobPointer in
                    if let optionsJSON, let convertJobOptionsJSON {
                        return optionsJSON.withCString { optionsPointer in
                            convertJobOptionsJSON(
                                session, outputPointer, jobPointer, optionsPointer,
                                chapterStart, chapterEnd,
                                ConverterCallbackBridge.progressCallback,
                                onChapterCompleted == nil ? nil : ConverterCallbackBridge.chapterCallback,
                                context
                            )
                        }
                    }
                    guard optionsJSON == nil else { throw EmbeddedConverterError.optionsABIUnavailable }
                    guard let convertJobJSON else {
                        throw EmbeddedConverterError.artifactInvalid("Loaded converter library lacks the callback conversion symbol.")
                    }
                    return convertJobJSON(
                        session, outputPointer, jobPointer, chapterStart, chapterEnd,
                        ConverterCallbackBridge.progressCallback,
                        onChapterCompleted == nil ? nil : ConverterCallbackBridge.chapterCallback,
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
        guard let json = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed("Rust returned invalid UTF-8 manifest JSON.")
        }
        return voiceReceipt.manifest(Data(json.utf8))
    }

    /// Capability check before book access or output reservation; never discard explicit options.
    func validateConversionSupport(options: ConversionOptions? = nil) throws {
        if let options {
            guard handle != nil,
                  (convertJobOptionsJSON != nil || convertStreamingJobOptionsJSON != nil),
                  let validateOptionsJSON else {
                throw EmbeddedConverterError.optionsABIUnavailable
            }
            guard setPlatformTts != nil else {
                throw EmbeddedConverterError.artifactInvalid("Loaded converter library lacks platform speech ABI.")
            }
            let json = try options.encodedJSON()
            let validator: ConverterOptionsValidateV1
            if options.requiresSessionABI {
                guard let validateSessionOptionsJSON else {
                    throw EmbeddedConverterError.artifactInvalid("Loaded converter library lacks version 2 session contracts.")
                }
                validator = validateSessionOptionsJSON
            } else { validator = validateOptionsJSON }
            guard json.withCString({ validator($0) }) else {
                throw EmbeddedConverterError.conversionFailed(readError())
            }
            return
        }
        guard handle != nil, convertJobJSON != nil || convertJSON != nil else {
            throw EmbeddedConverterError.artifactInvalid(
                "Loaded converter library lacks conversion symbols (job: \(convertJobJSON != nil), legacy: \(convertJSON != nil))."
            )
        }
        guard setPlatformTts != nil else {
            throw EmbeddedConverterError.artifactInvalid("Loaded converter library lacks platform speech ABI.")
        }
    }

    func ttsModels() throws -> Data { try modelCatalog.ttsModels() }
    func ttsCatalog() throws -> TtsCatalog { try modelCatalog.ttsCatalog() }
    func speechModelSnapshot(target: SpeechModelLibraryTarget, probeRuntime: Bool = false) throws -> SpeechModelSnapshot {
        try modelCatalog.speechModelSnapshot(target: target, probeRuntime: probeRuntime)
    }

    func ttsDefaultEngine(language: String, platform: String, androidAPI: UInt32 = 0) throws -> String {
        try modelCatalog.ttsDefaultEngine(language: language, platform: platform, androidAPI: androidAPI)
    }

    func ttsInstalledReadyEngine(language: String, platform: String, installedModelIDsJSON: String, readyModelIDsJSON: String, androidAPI: UInt32 = 0) throws -> String {
        try modelCatalog.ttsInstalledReadyEngine(language: language, platform: platform,
            installedModelIDsJSON: installedModelIDsJSON, readyModelIDsJSON: readyModelIDsJSON, androidAPI: androidAPI)
    }

    func installTtsModel(modelID: String, url: String, sha256: String, root: String) throws -> URL {
        try modelCatalog.installTtsModel(modelID: modelID, url: url, sha256: sha256, root: root)
    }

    func installTtsModelManifest(modelID: String, artifactsJSON: String, root: String) throws -> URL {
        try modelCatalog.installTtsModelManifest(modelID: modelID, artifactsJSON: artifactsJSON, root: root)
    }

    func installTtsModelFromCatalog(modelID: String, root: String) throws -> URL {
        try modelCatalog.installTtsModelFromCatalog(modelID: modelID, root: root)
    }

    func makeModelInstallOperation(
        modelID: String,
        root: URL,
        availableBytes: UInt64
    ) throws -> ConverterModelInstallOperation {
        try modelCatalog.makeInstallOperation(
            modelID: modelID,
            root: root,
            availableBytes: availableBytes
        )
    }

    func recoverModelInstallOperation(
        modelID: String,
        root: URL,
        availableBytes: UInt64
    ) throws -> ConverterModelInstallOperation? {
        try modelCatalog.recoverInstallOperation(
            modelID: modelID,
            root: root,
            availableBytes: availableBytes
        )
    }

    func removeTtsModel(modelID: String, root: String) throws {
        try modelCatalog.removeTtsModel(modelID: modelID, root: root)
    }

    func ttsModelMetadata(modelID: String, root: String) throws -> Data? {
        try modelCatalog.ttsModelMetadata(modelID: modelID, root: root)
    }

    private func readError() -> String {
        guard let value = lastError() else { return "unknown converter-ffi error" }
        defer { freeString(value) }
        guard let text = String(validatingCString: value) else { return "unknown converter-ffi error" }
        return text
    }
}
