import Foundation

/// Model ABI operations borrow the adapter-owned dylib and preserve owned-string freeing.
struct ConverterModelCatalog {
    var available = false
    var freeString: ConverterStringFree = { _ in }
    var lastError: ConverterLastError = { nil }
    var modelsJSON: ConverterTtsModels = { nil }
    var catalogJSON: ConverterTtsModels? = nil
    var catalogJSONV3: ConverterTtsCatalogV3? = nil
    var catalogProbeJSONV3: ConverterTtsCatalogProbeV3? = nil
    var defaultEngine: ConverterTtsDefaultEngine = { _, _, _ in nil }
    var selectInstalledReady: ConverterTtsInstalledReadyEngine?
    var installArtifact: ConverterTtsModelInstall?
    var removeModel: ConverterTtsModelRemove?
    var modelMetadata: ConverterTtsModelMetadata?
    var installManifest: ConverterTtsModelInstallManifest?
    var installCatalogManifest: ConverterTtsModelInstallCatalogManifest?
    var installOperationCreate: ConverterModelInstallOperationCreate?
    var installOperationRecover: ConverterModelInstallOperationRecover?
    var installOperationPlan: ConverterModelInstallOperationJSON?
    var installOperationEvent: ConverterModelInstallOperationJSON?
    var installOperationProgress: ConverterModelInstallOperationProgress?
    var installOperationAccept: ConverterModelInstallOperationAccept?
    var installOperationPublish: ConverterModelInstallOperationPublish?
    var installOperationFail: ConverterModelInstallOperationFail?
    var installOperationCancel: ConverterModelInstallOperationCancel?
    var installOperationFree: ConverterModelInstallOperationFree?

    func ttsCatalog() throws -> TtsCatalog {
        guard available, let read = catalogJSON, let value = read() else {
            throw EmbeddedConverterError.artifactUnavailable
        }
        defer { freeString(value) }
        guard let json = String(validatingCString: value) else {
            throw EmbeddedConverterError.artifactUnavailable
        }
        return try TtsCatalog.decode(Data(json.utf8))
    }

    func speechModelSnapshot(
        target: SpeechModelLibraryTarget,
        probeRuntime: Bool = false,
        espeakDataDirectory: String = Bundle.main.resourceURL?.path ?? ""
    ) throws -> SpeechModelSnapshot {
        guard available else {
            throw EmbeddedConverterError.artifactUnavailable
        }
        if probeRuntime {
            guard let probe = catalogProbeJSONV3 else { throw EmbeddedConverterError.artifactUnavailable }
            return try readProbedSnapshot(target: target, directory: espeakDataDirectory, probe: probe)
        }
        guard let read = catalogJSONV3 else { throw EmbeddedConverterError.artifactUnavailable }
        let result = target.language.withCString { languagePointer in
            target.platform.withCString { platformPointer in
                target.architecture.withCString { architecturePointer in
                    target.osVersion.withCString { osVersionPointer in
                        target.modelsRoot.path.withCString { rootPointer in
                            read(languagePointer, platformPointer, target.androidAPI,
                                 architecturePointer, osVersionPointer, rootPointer)
                        }
                    }
                }
            }
        }
        return try decodeSnapshot(result)
    }

    private func readProbedSnapshot(
        target: SpeechModelLibraryTarget, directory: String, probe: ConverterTtsCatalogProbeV3
    ) throws -> SpeechModelSnapshot {
        let result = target.language.withCString { language in
            target.platform.withCString { platform in
                target.architecture.withCString { architecture in
                    target.osVersion.withCString { osVersion in
                        target.modelsRoot.path.withCString { root in
                            directory.withCString { data in
                                probe(language, platform, target.androidAPI, architecture, osVersion, root, data)
                            }
                        }
                    }
                }
            }
        }
        return try decodeSnapshot(result)
    }

    private func decodeSnapshot(_ result: UnsafeMutablePointer<CChar>?) throws -> SpeechModelSnapshot {
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let json = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return try SpeechModelSnapshot.decode(Data(json.utf8))
    }

    func ttsModels() throws -> Data {
        guard available, let value = modelsJSON() else {
            throw EmbeddedConverterError.artifactUnavailable
        }
        defer { freeString(value) }
        guard let json = String(validatingCString: value) else {
            throw EmbeddedConverterError.artifactUnavailable
        }
        return Data(json.utf8)
    }

    func ttsDefaultEngine(language: String, platform: String, androidAPI: UInt32 = 0) throws -> String {
        guard available else { throw EmbeddedConverterError.artifactUnavailable }
        let result = language.withCString { languagePointer in
            platform.withCString { platformPointer in
                defaultEngine(languagePointer, platformPointer, androidAPI)
            }
        }
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let engine = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return engine
    }

    func ttsInstalledReadyEngine(language: String, platform: String, installedModelIDsJSON: String, readyModelIDsJSON: String, androidAPI: UInt32 = 0) throws -> String {
        guard available, let select = selectInstalledReady else { throw EmbeddedConverterError.artifactUnavailable }
        let result = language.withCString { languagePointer in
            platform.withCString { platformPointer in
                installedModelIDsJSON.withCString { installedPointer in
                    readyModelIDsJSON.withCString { readyPointer in
                        select(languagePointer, platformPointer, androidAPI, installedPointer, readyPointer)
                    }
                }
            }
        }
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let engine = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return engine
    }

    func installTtsModel(modelID: String, url: String, sha256: String, root: String) throws -> URL {
        guard available, let install = installArtifact else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            url.withCString { urlPointer in
                sha256.withCString { hashPointer in
                    root.withCString { rootPointer in
                        install(modelPointer, urlPointer, hashPointer, rootPointer)
                    }
                }
            }
        }
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let path = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return URL(fileURLWithPath: path)
    }

    func installTtsModelManifest(modelID: String, artifactsJSON: String, root: String) throws -> URL {
        guard available, let install = installManifest else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            artifactsJSON.withCString { artifactsPointer in
                root.withCString { rootPointer in
                    install(modelPointer, artifactsPointer, rootPointer)
                }
            }
        }
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let path = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return URL(fileURLWithPath: path)
    }

    func installTtsModelFromCatalog(modelID: String, root: String) throws -> URL {
        guard available, let install = installCatalogManifest else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            root.withCString { rootPointer in
                install(modelPointer, rootPointer)
            }
        }
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let path = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return URL(fileURLWithPath: path)
    }

    func makeInstallOperation(
        modelID: String,
        root: URL,
        availableBytes: UInt64
    ) throws -> ConverterModelInstallOperation {
        guard let operation = try loadInstallOperation(
            modelID: modelID,
            root: root,
            availableBytes: availableBytes,
            recoverOnly: false
        ) else {
            throw EmbeddedConverterError.conversionFailed("Model install operation was not created")
        }
        return operation
    }

    func recoverInstallOperation(
        modelID: String,
        root: URL,
        availableBytes: UInt64
    ) throws -> ConverterModelInstallOperation? {
        try loadInstallOperation(
            modelID: modelID,
            root: root,
            availableBytes: availableBytes,
            recoverOnly: true
        )
    }

    private func loadInstallOperation(
        modelID: String,
        root: URL,
        availableBytes: UInt64,
        recoverOnly: Bool
    ) throws -> ConverterModelInstallOperation? {
        guard available,
              let create = installOperationCreate,
              let plan = installOperationPlan,
              let event = installOperationEvent,
              let progress = installOperationProgress,
              let accept = installOperationAccept,
              let publish = installOperationPublish,
              let fail = installOperationFail,
              let cancel = installOperationCancel,
              let release = installOperationFree else {
            throw EmbeddedConverterError.artifactUnavailable
        }
        let createOrRecover: ConverterModelInstallOperationCreate
        if recoverOnly {
            guard let recover = installOperationRecover else {
                throw EmbeddedConverterError.artifactUnavailable
            }
            createOrRecover = recover
        } else {
            createOrRecover = create
        }
        let handle = modelID.withCString { modelPointer in
            root.path.withCString { rootPointer in
                createOrRecover(modelPointer, rootPointer, availableBytes)
            }
        }
        if recoverOnly, handle == nil {
            if let error = takeError() {
                throw EmbeddedConverterError.conversionFailed(error)
            }
            return nil
        }
        guard let handle else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return ConverterModelInstallOperation(
            handle: handle,
            planJSON: plan,
            eventJSON: event,
            recordProgress: progress,
            acceptDownload: accept,
            publish: publish,
            fail: fail,
            cancel: cancel,
            release: release,
            freeString: freeString,
            lastError: lastError
        )
    }

    func removeTtsModel(modelID: String, root: String) throws {
        guard available, let remove = removeModel else { throw EmbeddedConverterError.artifactUnavailable }
        let removed = modelID.withCString { modelPointer in
            root.withCString { rootPointer in
                remove(modelPointer, rootPointer)
            }
        }
        guard removed else { throw EmbeddedConverterError.conversionFailed(readError()) }
    }

    func ttsModelMetadata(modelID: String, root: String) throws -> Data? {
        guard available, let metadata = modelMetadata else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            root.withCString { rootPointer in metadata(modelPointer, rootPointer) }
        }
        guard let value = result else { return nil }
        defer { freeString(value) }
        guard let json = String(validatingCString: value) else { throw EmbeddedConverterError.conversionFailed(readError()) }
        return Data(json.utf8)
    }

    private func readError() -> String {
        takeError() ?? "unknown converter-ffi error"
    }

    private func takeError() -> String? {
        guard let value = lastError() else { return nil }
        defer { freeString(value) }
        return String(validatingCString: value)
    }
}
